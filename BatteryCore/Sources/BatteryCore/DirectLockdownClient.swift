import Foundation

/// Talks lockdown straight to a phone's IP, with no usbmuxd in the path.
///
/// Why this exists: usbmuxd discovers network devices over Bonjour, and the
/// `_apple-mobdev2._tcp` record for a sleeping iPhone disappears for ~40 s at a
/// time (NOTES.md §5). During those windows `idevice_get_device_list_extended`
/// is empty and every libimobiledevice call fails — but the phone itself is
/// still listening on port 62078 and answers happily. Measured during blackouts:
/// raw TCP connect 23/24, full battery read 13/14.
///
/// The only thing we still take from usbmuxd is the **pair record**, which it
/// will hand over regardless of whether the device is currently visible.
///
/// The protocol, all of it implemented here over a plain socket + OpenSSL:
///
/// ```
/// connect <ip>:62078
///   -> {Label, Request: "QueryType"}                     <- {Type: "com.apple.mobile.lockdown"}
///   -> {Label, Request: "StartSession", HostID, SystemBUID}
///                                                        <- {SessionID, EnableSessionSSL: true}
///   upgrade the SAME socket to TLS (host cert + key as the client identity)
///   -> {Label, Request: "StartService", Service: "com.apple.mobile.diagnostics_relay"}
///                                                        <- {Port, EnableServiceSSL}
/// connect <ip>:Port  (TLS again if EnableServiceSSL)
///   -> {Request: "IORegistry", EntryName: "AppleSmartBattery"}
///                                                        <- {Status: "Success", Diagnostics: {IORegistry: {...}}}
///   -> {Request: "Goodbye"} on both, close both
/// ```
public actor DirectLockdownClient {

    public struct Options: Sendable, Equatable {
        /// TCP connect budget. The lead measured a first connect after a pause
        /// taking up to 2.3 s, so this has real headroom.
        public var connectTimeout: TimeInterval
        /// Per read and per write.
        public var ioTimeout: TimeInterval
        /// Hard cap on one whole attempt, connect to Goodbye.
        public var overallTimeout: TimeInterval
        /// The `Label` lockdownd sees. Cosmetic.
        public var label: String
        /// lockdownd's well-known port.
        public var port: UInt16

        public init(
            connectTimeout: TimeInterval = 8,
            ioTimeout: TimeInterval = 8,
            overallTimeout: TimeInterval = 15,
            label: String = "tandem",
            port: UInt16 = 62078
        ) {
            self.connectTimeout = connectTimeout
            self.ioTimeout = ioTimeout
            self.overallTimeout = overallTimeout
            self.label = label
            self.port = port
        }
    }

    public static let diagnosticsService = "com.apple.mobile.diagnostics_relay"
    public static let legacyDiagnosticsService = "com.apple.iosdiagnostics.relay"

    public private(set) var options: Options

    public init(options: Options = Options()) {
        self.options = options
    }

    public func setOptions(_ options: Options) {
        self.options = options
    }

    // MARK: - Public reads

    /// Read `AppleSmartBattery` from the phone at `host` and decode it.
    public func readBattery(
        udid: String,
        host: String,
        name: String = "iPhone",
        timestamp: Date = Date()
    ) async throws -> BatteryReading {
        try await readBattery(udid: udid, hosts: [host], name: name, timestamp: timestamp)
    }

    /// Try each address in turn, best first, inside one overall deadline.
    ///
    /// There is usually more than one: usbmuxd knows the phone by its IPv6
    /// link-local, and `NeighborTable` can usually also name an IPv4 for the
    /// same hardware. Only the IPv4 answers while the phone naps, so it goes
    /// first — but the link-local is kept, because on a network with no ARP
    /// entry it may be all we have.
    public func readBattery(
        udid: String,
        hosts: [String],
        name: String = "iPhone",
        timestamp: Date = Date(),
        options: Options? = nil
    ) async throws -> BatteryReading {
        let data = try await ioRegistryPlist(udid: udid, hosts: hosts, options: options)
        var reading = try BatteryPlistParser.parseIPhone(
            data,
            deviceID: udid,
            name: name,
            transport: .wifi,
            timestamp: timestamp
        )
        reading.viaDirect = true
        return reading
    }

    /// The raw IORegistry reply as a binary plist — same shape the
    /// libimobiledevice path produces, so `BatteryPlistParser` eats either.
    public func ioRegistryPlist(
        udid: String,
        host: String,
        entryName: String = PhoneBatterySource.ioRegistryEntryName
    ) async throws -> Data {
        try await ioRegistryPlist(udid: udid, hosts: [host], entryName: entryName)
    }

    public func ioRegistryPlist(
        udid: String,
        hosts: [String],
        entryName: String = PhoneBatterySource.ioRegistryEntryName,
        options: Options? = nil
    ) async throws -> Data {
        guard !hosts.isEmpty else { throw DirectLockdownError.noAddress(udid: udid) }
        let record = try PairRecordStore.read(udid: udid)
        return try await run(hosts: hosts, record: record, entryName: entryName, options: options ?? self.options)
    }

    /// The **degraded tier**: lockdown `GetValue` on `com.apple.mobile.battery`,
    /// decoded into a partial `BatteryReading`.
    ///
    /// Measured at 9/14 against the relay's 4/14 in the same windows
    /// (NOTES.md §12.9), because it stops one protocol step earlier — no
    /// `StartService`, no second socket, no service TLS.
    public func readBatteryDomain(
        udid: String,
        hosts: [String],
        name: String = "iPhone",
        timestamp: Date = Date(),
        options: Options? = nil
    ) async throws -> BatteryReading {
        let data = try await lockdownValue(
            udid: udid,
            hosts: hosts,
            domain: BatteryPlistParser.batteryDomain,
            options: options
        )
        return try BatteryPlistParser.parseBatteryDomain(
            data,
            deviceID: udid,
            name: name,
            transport: .wifi,
            viaDirect: true,
            timestamp: timestamp
        )
    }

    /// `GetValue` against lockdownd itself, no service involved.
    ///
    /// Useful because it stops one step earlier than `ioRegistryPlist`: if this
    /// works and the IORegistry read does not, the phone is up and lockdownd is
    /// answering while `diagnostics_relay` refuses. `com.apple.mobile.battery`
    /// carries `BatteryCurrentCapacity` and `BatteryIsCharging` — far less than
    /// AppleSmartBattery, but available without a service.
    public func lockdownValue(
        udid: String,
        hosts: [String],
        domain: String? = nil,
        key: String? = nil,
        options overrides: Options? = nil
    ) async throws -> Data {
        guard !hosts.isEmpty else { throw DirectLockdownError.noAddress(udid: udid) }
        let record = try PairRecordStore.read(udid: udid)
        let options = overrides ?? self.options
        let label = options.label
        let cap = options.overallTimeout

        let worker = Task.detached(priority: .utility) { () throws -> Data in
            var firstError: Error?
            for host in hosts {
                do {
                    return try Self.getValueBlocking(
                        host: host, record: record, domain: domain, key: key,
                        label: label, options: options
                    )
                } catch {
                    if firstError == nil { firstError = error }
                    if case DirectLockdownError.timedOut(let step, _) = error, step.hasPrefix("connect ") {
                        break
                    }
                }
            }
            throw firstError ?? DirectLockdownError.noAddress(udid: udid)
        }
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await worker.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(cap))
                return nil
            }
            defer {
                group.cancelAll()
                worker.cancel()
            }
            while let outcome = try await group.next() {
                if let outcome { return outcome }
                throw DirectLockdownError.timedOut(step: "whole attempt", after: cap)
            }
            throw DirectLockdownError.emptyResponse
        }
    }

    private static func getValueBlocking(
        host: String,
        record: PairRecord,
        domain: String?,
        key: String?,
        label: String,
        options: Options
    ) throws -> Data {
        let lockdown = try LockdownSocket.connect(
            host: host, port: options.port,
            connectTimeout: options.connectTimeout, ioTimeout: options.ioTimeout
        )
        defer { lockdown.close() }

        _ = try lockdown.request(["Label": label, "Request": "QueryType"], step: "QueryType")
        let session = try lockdown.request(
            [
                "Label": label, "Request": "StartSession",
                "HostID": record.hostID, "SystemBUID": record.systemBUID,
            ],
            step: "StartSession"
        )
        if (session["EnableSessionSSL"] as? NSNumber)?.boolValue ?? false {
            try lockdown.startTLS(
                certificate: record.hostCertificate,
                privateKey: record.hostPrivateKey,
                step: "session TLS"
            )
        }

        var message: [String: Any] = ["Label": label, "Request": "GetValue"]
        if let domain { message["Domain"] = domain }
        if let key { message["Key"] = key }
        let reply = try lockdown.request(message, step: "GetValue")
        guard let value = reply["Value"] else {
            throw DirectLockdownError.protocolError(
                step: "GetValue",
                detail: "no Value in \(reply.keys.sorted())"
            )
        }
        _ = try? lockdown.request(["Label": label, "Request": "Goodbye"], step: "Goodbye(lockdown)")
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: value, format: .xml, options: 0
            )
        } catch {
            throw DirectLockdownError.protocolError(
                step: "GetValue",
                detail: "could not re-encode the value: \(error.localizedDescription)"
            )
        }
    }

    /// Just the TCP reachability question, for diagnostics: can we open 62078?
    public func canConnect(host: String) async -> Bool {
        let options = self.options
        let task = Task.detached(priority: .utility) { () -> Bool in
            guard let socket = try? LockdownSocket.connect(
                host: host,
                port: options.port,
                connectTimeout: options.connectTimeout,
                ioTimeout: options.ioTimeout
            ) else { return false }
            socket.close()
            return true
        }
        return await task.value
    }

    // MARK: - The attempt

    private func run(
        hosts: [String],
        record: PairRecord,
        entryName: String,
        options: Options
    ) async throws -> Data {
        let label = options.label
        let cap = options.overallTimeout

        let worker = Task.detached(priority: .utility) { () throws -> Data in
            let deadline = Date().addingTimeInterval(cap)
            // The first candidate is the one we believe in, so its failure is
            // the one worth reporting; the others are consolation attempts.
            var firstError: Error?

            candidates: for host in hosts {
                for attempt in 1...2 {
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 1 else { break candidates }

                    var attemptOptions = options
                    // Never let one dead address eat the whole budget.
                    attemptOptions.connectTimeout = max(1, min(options.connectTimeout, remaining))
                    do {
                        return try Self.performBlocking(
                            host: host,
                            record: record,
                            entryName: entryName,
                            label: label,
                            options: attemptOptions
                        )
                    } catch {
                        if firstError == nil { firstError = error }

                        // A connect timeout means the phone answered no SYN at
                        // all, so it is asleep or off the air; neither a retry
                        // nor its other address will do better, and trying
                        // doubles the cost of an already-expensive failure.
                        if case DirectLockdownError.timedOut(let step, _) = error,
                           step.hasPrefix("connect ") {
                            break candidates
                        }

                        // We got far enough to talk to the device and it hung up
                        // mid-exchange — diagnostics_relay does this to a
                        // half-awake phone, roughly once in fourteen tries. The
                        // immediate retry almost always lands, and those are
                        // exactly the moments usbmuxd is still blind.
                        if attempt == 1 { continue }
                    }
                }
            }
            throw firstError ?? DirectLockdownError.noAddress(udid: "")
        }

        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await worker.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(cap))
                return nil
            }
            defer {
                group.cancelAll()
                worker.cancel()
            }
            while let outcome = try await group.next() {
                if let outcome { return outcome }
                throw DirectLockdownError.timedOut(step: "whole attempt", after: cap)
            }
            throw DirectLockdownError.emptyResponse
        }
    }

    /// Everything below runs on a detached task; it blocks, and it owns and
    /// closes both sockets itself, so abandoning it on timeout leaks nothing
    /// beyond the two file descriptors the `defer`s reclaim.
    private static func performBlocking(
        host: String,
        record: PairRecord,
        entryName: String,
        label: String,
        options: Options
    ) throws -> Data {
        let lockdown = try LockdownSocket.connect(
            host: host,
            port: options.port,
            connectTimeout: options.connectTimeout,
            ioTimeout: options.ioTimeout
        )
        defer { lockdown.close() }

        // 1. QueryType. Confirms we are talking to lockdownd and not to some
        //    other process that grabbed the port.
        let queryType = try lockdown.request(
            ["Label": label, "Request": "QueryType"],
            step: "QueryType"
        )
        if let type = queryType["Type"] as? String, type != "com.apple.mobile.lockdown" {
            throw DirectLockdownError.protocolError(step: "QueryType", detail: "Type is \(type)")
        }

        // 2. StartSession with the pair record's identity.
        let session = try lockdown.request(
            [
                "Label": label,
                "Request": "StartSession",
                "HostID": record.hostID,
                "SystemBUID": record.systemBUID,
            ],
            step: "StartSession"
        )
        let sessionID = session["SessionID"] as? String
        let needsSessionTLS = (session["EnableSessionSSL"] as? NSNumber)?.boolValue ?? false

        // 3. Upgrade this very socket. Nothing further is readable in the clear.
        if needsSessionTLS {
            try lockdown.startTLS(
                certificate: record.hostCertificate,
                privateKey: record.hostPrivateKey,
                step: "session TLS"
            )
        }

        // 4. StartService. iOS answers with a port and whether that port also
        //    wants TLS (it does, on anything modern).
        var startService: [String: Any]
        do {
            startService = try lockdown.request(
                ["Label": label, "Request": "StartService", "Service": diagnosticsService],
                step: "StartService"
            )
        } catch DirectLockdownError.lockdownRefused(_, let error) where error == "InvalidService" {
            startService = try lockdown.request(
                ["Label": label, "Request": "StartService", "Service": legacyDiagnosticsService],
                step: "StartService(legacy)"
            )
        }
        guard let servicePort = (startService["Port"] as? NSNumber)?.uint16Value, servicePort > 0 else {
            throw DirectLockdownError.protocolError(
                step: "StartService",
                detail: "no usable Port in \(startService.keys.sorted())"
            )
        }
        let needsServiceTLS = (startService["EnableServiceSSL"] as? NSNumber)?.boolValue ?? false

        // 5. Second connection, to the service port.
        let relay = try LockdownSocket.connect(
            host: host,
            port: servicePort,
            connectTimeout: options.connectTimeout,
            ioTimeout: options.ioTimeout
        )
        defer { relay.close() }
        if needsServiceTLS {
            try relay.startTLS(
                certificate: record.hostCertificate,
                privateKey: record.hostPrivateKey,
                step: "service TLS"
            )
        }

        // 6. The actual question.
        let reply = try relay.request(
            ["Request": "IORegistry", "EntryName": entryName],
            step: "IORegistry"
        )
        let data = try extractIORegistry(reply)

        // 7. Goodbye on both. Best effort — the answer is already in hand.
        _ = try? relay.request(["Request": "Goodbye"], step: "Goodbye(relay)")
        if sessionID != nil {
            _ = try? lockdown.request(["Label": label, "Request": "Goodbye"], step: "Goodbye(lockdown)")
        }
        return data
    }

    /// `{Status: "Success", Diagnostics: {IORegistry: {...}}}` down to the
    /// dictionary `BatteryPlistParser` wants, re-serialised as a binary plist so
    /// the two read paths hand the parser the same thing.
    static func extractIORegistry(_ reply: [String: Any]) throws -> Data {
        if let status = reply["Status"] as? String, status != "Success" {
            throw DirectLockdownError.protocolError(step: "IORegistry", detail: "Status is \(status)")
        }
        guard let diagnostics = reply["Diagnostics"] as? [String: Any] else {
            throw DirectLockdownError.protocolError(
                step: "IORegistry",
                detail: "no Diagnostics in \(reply.keys.sorted())"
            )
        }
        guard let entry = diagnostics["IORegistry"] as? [String: Any], !entry.isEmpty else {
            throw DirectLockdownError.emptyResponse
        }
        do {
            return try PropertyListSerialization.data(
                fromPropertyList: entry,
                format: .binary,
                options: 0
            )
        } catch {
            throw DirectLockdownError.protocolError(
                step: "IORegistry",
                detail: "could not re-encode the entry: \(error.localizedDescription)"
            )
        }
    }
}
