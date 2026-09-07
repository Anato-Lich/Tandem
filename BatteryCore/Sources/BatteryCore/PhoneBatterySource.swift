import Foundation
import CLibimobiledevice

/// An iOS device visible to usbmuxd.
public struct PhoneDevice: Sendable, Codable, Equatable, Hashable {
    public var udid: String
    public var name: String
    /// `.usb` or `.wifi`. When a device is on both, USB wins.
    public var transport: Transport

    public init(udid: String, name: String, transport: Transport) {
        self.udid = udid
        self.name = name
        self.transport = transport
    }
}

/// usbmuxd attach/detach notifications.
public enum PhoneEvent: Sendable, Equatable {
    case attached(udid: String, transport: Transport)
    case detached(udid: String)
    case paired(udid: String)

    public var udid: String {
        switch self {
        case .attached(let udid, _), .detached(let udid), .paired(let udid): return udid
        }
    }
}

public enum PhoneError: Error, Equatable, Sendable, CustomStringConvertible {
    /// usbmuxd knows of no such device. Over Wi-Fi this is routinely transient:
    /// the Bonjour record for `_apple-mobdev2._tcp` comes and goes, so callers
    /// should retry before believing it.
    case noDevice(udid: String?)
    /// Lockdown handshake refused: no pair record, or the user has not trusted us.
    case notPaired(code: Int32)
    /// Transport-level failure talking to the device.
    case unreachable(code: Int32)
    /// `com.apple.mobile.diagnostics_relay` would not start.
    case serviceFailed(code: Int32)
    /// The diagnostics query itself failed.
    case queryFailed(code: Int32)
    /// The device answered, but with nothing usable.
    case emptyResponse
    /// The read did not finish inside the deadline. Typically a stale Bonjour
    /// record: the TCP connect to a phone that is no longer there can sit for
    /// tens of seconds before libimobiledevice gives up.
    case timedOut(after: TimeInterval)

    public var description: String {
        switch self {
        case .noDevice(let udid):
            return "No device found\(udid.map { " with udid \($0)" } ?? "")"
        case .notPaired(let code):
            return "Device is not paired or trust was not granted (lockdown \(code))"
        case .unreachable(let code):
            return "Could not reach device (lockdown \(code))"
        case .serviceFailed(let code):
            return "Could not start com.apple.mobile.diagnostics_relay (lockdown \(code))"
        case .queryFailed(let code):
            return "diagnostics_relay ioregistry query failed (\(code))"
        case .emptyResponse:
            return "Device returned an empty AppleSmartBattery entry"
        case .timedOut(let seconds):
            return String(format: "Device did not respond within %.1f s", seconds)
        }
    }

    /// True for failures that are worth retrying in a few seconds.
    public var isTransient: Bool {
        switch self {
        case .noDevice, .unreachable, .serviceFailed, .queryFailed, .emptyResponse, .timedOut:
            return true
        case .notPaired:
            return false
        }
    }
}

/// How hard to try before declaring a phone unreachable.
///
/// A phone that has just been unplugged takes 10-30 s to publish its Wi-Fi
/// Bonjour record, and the record then flaps for a minute or so, so a single
/// "no device found" means nothing.
public struct PhoneRetryPolicy: Sendable, Equatable {
    public var attempts: Int
    public var gap: TimeInterval
    /// Per-attempt wall-clock budget, or nil to wait as long as libimobiledevice
    /// does. Worth setting: a stale Wi-Fi Bonjour record has been measured to
    /// block a single read for ~48 s.
    public var deadline: TimeInterval?

    public init(attempts: Int = 3, gap: TimeInterval = 3, deadline: TimeInterval? = 8) {
        self.attempts = max(1, attempts)
        self.gap = max(0, gap)
        self.deadline = deadline
    }

    public static let `default` = PhoneRetryPolicy()
    public static let none = PhoneRetryPolicy(attempts: 1, gap: 0, deadline: nil)
}

/// Talks to iPhones over usbmuxd using libimobiledevice's C API.
///
/// By default a lockdown + diagnostics_relay session is opened and closed per
/// read (see NOTES.md for measured latency). Turn on `setKeepAlive(true)` to
/// reuse the relay connection between reads, which removes the Wi-Fi
/// rediscovery flap at the cost of holding a socket open.
public actor PhoneBatterySource {

    /// The IORegistry entry we ask for. `entry_class` is deliberately empty,
    /// matching what `idevicediagnostics ioregentry AppleSmartBattery` sends.
    public static let ioRegistryEntryName = "AppleSmartBattery"
    private static let clientLabel = "tandem"
    private static let diagnosticsService = "com.apple.mobile.diagnostics_relay"
    private static let legacyDiagnosticsService = "com.apple.iosdiagnostics.relay"

    /// A live device + diagnostics_relay pair, kept only when keep-alive is on.
    ///
    /// `@unchecked Sendable`: the C handles inside are only ever touched from
    /// this actor (or from `deinit`, which runs after the last reference is
    /// gone), so no two threads can race on them.
    private struct Session: @unchecked Sendable {
        var device: idevice_t
        var service: lockdownd_service_descriptor_t
        var relay: diagnostics_relay_client_t
        var openedAt: Date
        var transport: Transport
    }

    private var nameCache: [String: String] = [:]
    private var sessions: [String: Session] = [:]
    private var keepAlive = false
    public private(set) var retryPolicy: PhoneRetryPolicy

    /// Where the phone was last seen on the network, so the direct client has
    /// somewhere to dial when usbmuxd cannot see it.
    public nonisolated let addressBook: PhoneAddressBook
    /// The no-usbmuxd path. See NOTES.md §12.
    public nonisolated let directClient: DirectLockdownClient
    /// How the direct-first decision is made. Mutable so a caller can turn the
    /// whole thing off without changing call sites.
    public private(set) var directPolicy: DirectFirstReader

    /// Why the last read did not use the direct path (or how it failed there).
    /// `nil` after a read that went direct successfully.
    public private(set) var lastDirectError: String?

    /// Which leg produced the last reading. `nil` before the first read.
    public private(set) var lastRoute: PhoneReadRace.Route?
    /// Every leg that failed on the last read, by route.
    public private(set) var lastRouteErrors: [PhoneReadRace.Route: String] = [:]

    /// Ordering and budget for the two-tier read. See NOTES.md §13.
    public private(set) var race = PhoneReadRace()

    public func setRace(_ race: PhoneReadRace) {
        self.race = race
    }

    public init(
        retryPolicy: PhoneRetryPolicy = .default,
        addressBook: PhoneAddressBook = PhoneAddressBook(),
        directClient: DirectLockdownClient = DirectLockdownClient(),
        directPolicy: DirectFirstReader = DirectFirstReader()
    ) {
        self.retryPolicy = retryPolicy
        self.addressBook = addressBook
        self.directClient = directClient
        self.directPolicy = directPolicy
    }

    public func setDirectPolicy(_ policy: DirectFirstReader) {
        directPolicy = policy
    }

    deinit {
        for session in sessions.values {
            diagnostics_relay_goodbye(session.relay)
            diagnostics_relay_client_free(session.relay)
            lockdownd_service_descriptor_free(session.service)
            idevice_free(session.device)
        }
    }

    public func setRetryPolicy(_ policy: PhoneRetryPolicy) {
        retryPolicy = policy
    }

    /// Reuse the diagnostics_relay connection across reads.
    public func setKeepAlive(_ enabled: Bool) {
        keepAlive = enabled
        if !enabled { closeAllSessions() }
    }

    public var isKeepAliveEnabled: Bool { keepAlive }

    // MARK: - Discovery

    /// Every iOS device usbmuxd currently lists, de-duplicated with USB winning
    /// over Wi-Fi.
    ///
    /// This never talks to the device, so it always returns promptly; names come
    /// from the cache and fall back to a placeholder. Use `discoverWithRetry()`
    /// if you want real names.
    public func discover() -> [PhoneDevice] {
        var byUDID: [String: Transport] = [:]
        var order: [String] = []

        var list: UnsafeMutablePointer<idevice_info_t?>?
        var count: Int32 = 0
        guard idevice_get_device_list_extended(&list, &count) == IDEVICE_E_SUCCESS, let list else {
            return []
        }
        defer { idevice_device_list_extended_free(list) }

        for index in 0..<Int(count) {
            guard let info = list[index]?.pointee, let udidPointer = info.udid else { continue }
            let udid = String(cString: udidPointer)
            let transport: Transport = (info.conn_type == CONNECTION_NETWORK) ? .wifi : .usb
            if let existing = byUDID[udid] {
                if existing == .wifi && transport == .usb { byUDID[udid] = .usb }
            } else {
                byUDID[udid] = transport
                order.append(udid)
            }
        }

        return order.map { udid in
            let transport = byUDID[udid] ?? .usb
            return PhoneDevice(udid: udid, name: nameCache[udid] ?? "iPhone", transport: transport)
        }
    }

    /// Everything we can attempt a read on: what usbmuxd can see *plus* anything
    /// the address book remembers.
    ///
    /// This is what the direct path needs. `discover()` and `discoverWithRetry()`
    /// both go blind during a Bonjour blackout — which is precisely when the
    /// direct client is worth using — so a remembered phone is offered as a
    /// `.wifi` device even though usbmuxd has never heard of it.
    public func addressableDevices() async -> [PhoneDevice] {
        var result = discover()
        if !result.isEmpty {
            await addressBook.refreshFromUSBMux()
            // Resolve real names while the device is visible; the result is
            // cached in the address book so a later blackout read can still use
            // it. Costs one lockdown handshake, once per process.
            for index in result.indices {
                result[index].name = await name(
                    for: result[index].udid,
                    transport: result[index].transport
                )
            }
        }
        let seen = Set(result.map(\.udid))
        for entry in await addressBook.all() where !seen.contains(entry.udid) {
            result.append(
                PhoneDevice(
                    udid: entry.udid,
                    name: nameCache[entry.udid] ?? entry.name ?? "iPhone",
                    transport: .wifi
                )
            )
        }
        return result
    }

    /// `discover()`, but tolerant of the Wi-Fi Bonjour record flapping, and it
    /// fills in real device names.
    public func discoverWithRetry(_ policy: PhoneRetryPolicy? = nil) async -> [PhoneDevice] {
        let policy = policy ?? retryPolicy
        for attempt in 1...policy.attempts {
            let found = discover()
            if !found.isEmpty {
                // We can see the phone right now, which is the only time usbmuxd
                // will tell us its IP. Grab it for the direct path later.
                await addressBook.refreshFromUSBMux()
                var named: [PhoneDevice] = []
                named.reserveCapacity(found.count)
                for var device in found {
                    device.name = await name(for: device.udid, transport: device.transport)
                    named.append(device)
                }
                return named
            }
            if attempt < policy.attempts, policy.gap > 0 {
                try? await Task.sleep(for: .seconds(policy.gap))
                if Task.isCancelled { return [] }
            }
        }
        return []
    }

    /// Lockdown `DeviceName`, cached per udid. Falls back to a placeholder if the
    /// device does not answer inside the deadline.
    public func name(for udid: String, transport: Transport) async -> String {
        if let cached = nameCache[udid] { return cached }
        let deadline = retryPolicy.deadline
        let resolved = try? await Self.withDeadline(deadline) {
            Data(try Self.fetchDeviceName(udid: udid, transport: transport).utf8)
        }
        guard let resolved, let text = String(data: resolved, encoding: .utf8), !text.isEmpty else {
            return "iPhone"
        }
        nameCache[udid] = text
        await addressBook.recordName(text, for: udid)
        return text
    }

    public func forgetName(_ udid: String) {
        nameCache.removeValue(forKey: udid)
    }

    // MARK: - Reading

    /// Read the phone's battery, retrying transient failures.
    ///
    /// Over Wi-Fi this goes **direct by IP first** (see `DirectLockdownClient`)
    /// and only falls back to usbmuxd when that fails, because usbmuxd's Bonjour
    /// device list vanishes for ~40 s at a time while the phone sleeps and the
    /// phone itself stays perfectly reachable throughout. Over USB, and when
    /// `useDirectClient` is false, this is the original usbmuxd-only path.
    public func read(
        _ device: PhoneDevice,
        timestamp: Date = Date(),
        useDirectClient: Bool = true
    ) async throws -> BatteryReading {
        var policy = directPolicy
        if !useDirectClient { policy.useDirect = false; policy.directOnly = false }
        // A cabled device is not flapping; there is nothing for the direct path
        // to fix, and its IP may not even be routable.
        if device.transport == .usb { policy.useDirect = false; policy.directOnly = false }

        guard policy.useDirect || policy.directOnly else {
            lastDirectError = "direct path disabled"
            lastRoute = .usbmux
            lastRouteErrors = [:]
            return try await readViaUSBMux(device, timestamp: timestamp)
        }

        return try await readTiered(device, timestamp: timestamp, policy: policy)
    }

    /// The two-tier, two-transport read. See NOTES.md §13.
    ///
    /// Tier 1 races the direct-by-IP client against usbmuxd and takes the first
    /// success; tier 2 asks lockdown's `com.apple.mobile.battery` domain for the
    /// four fields it will still answer with when `diagnostics_relay` will not.
    /// The whole thing is capped at `race.budget` (8 s), which is what stopped a
    /// blackout costing ~14 s: the 8 s direct connect no longer runs *before* a
    /// usbmuxd path that fails in a millisecond, it runs beside it.
    private func readTiered(
        _ device: PhoneDevice,
        timestamp: Date,
        policy: DirectFirstReader
    ) async throws -> BatteryReading {
        let started = Date()
        let cached = await addressBook.dialableAddress(for: device.udid)
        let hosts = policy.shouldTryDirect(cached, now: timestamp) ? (cached?.candidates ?? []) : []
        let hasAddress = !hosts.isEmpty

        if policy.directOnly, !hasAddress {
            lastRoute = nil
            lastDirectError = cached == nil ? "no cached address" : "cached address is too old"
            throw DirectLockdownError.noAddress(udid: device.udid)
        }

        // `discover()` never touches the device — it is a sub-millisecond read of
        // usbmuxd's list — so asking first is free, and it is what decides how
        // much of the budget the direct connect may take.
        let usbmuxAllowed = !policy.directOnly
        let usbmuxVisible = usbmuxAllowed && discover().contains { $0.udid == device.udid }

        // Racing means the budget is the *slower* leg, not the sum. When usbmuxd
        // is blind there is nothing to race, so the direct connect is clipped to
        // 4 s to leave the degraded tier room inside the same 8 s.
        let fullBudget: TimeInterval = usbmuxVisible ? min(5, race.budget) : min(4, race.budget)
        let partialBudget = max(1, race.budget - fullBudget)

        let client = directClient
        let udid = device.udid
        let name = device.name
        let book = addressBook
        let base = await directClient.options

        let fullOptions: DirectLockdownClient.Options = {
            var options = base
            options.connectTimeout = min(options.connectTimeout, fullBudget)
            options.ioTimeout = min(options.ioTimeout, fullBudget)
            options.overallTimeout = fullBudget
            return options
        }()
        let partialOptions: DirectLockdownClient.Options = {
            var options = base
            options.connectTimeout = partialBudget
            options.ioTimeout = partialBudget
            options.overallTimeout = partialBudget
            return options
        }()

        var full: [PhoneReadRace.Leg] = []
        var partial: [PhoneReadRace.Leg] = []

        if hasAddress {
            full.append(.init(.direct) {
                try await client.readBattery(
                    udid: udid, hosts: hosts, name: name,
                    timestamp: timestamp, options: fullOptions
                )
            })
            // Direct first in the degraded tier too: GetValue answered 9/14
            // against the relay's 4/14 in the same windows (NOTES.md §12.9).
            partial.append(.init(.directPartial) {
                try await client.readBatteryDomain(
                    udid: udid, hosts: hosts, name: name,
                    timestamp: timestamp, options: partialOptions
                )
            })
        }
        if usbmuxAllowed {
            full.append(.init(.usbmux) {
                try await self.readViaUSBMuxOnce(device, timestamp: timestamp, deadline: fullBudget)
            })
            partial.append(.init(.usbmuxPartial) {
                try await self.readPartialViaUSBMux(
                    device, timestamp: timestamp, deadline: partialBudget
                )
            })
        }

        do {
            let outcome = try await race.read(full: full, partial: partial, startedAt: started)
            lastRoute = outcome.route
            lastRouteErrors = outcome.errors
            lastDirectError = hasAddress
                ? outcome.errors[.direct]
                : (cached == nil ? "no cached address" : "cached address is too old")
            if !outcome.route.usesDirect {
                // usbmuxd just proved it can see the phone, which is the one
                // moment it will tell us where the phone lives.
                _ = await book.refreshFromUSBMux().first(where: { $0.udid == udid })?.host
            }
            return outcome.reading
        } catch {
            lastRoute = nil
            lastDirectError = hasAddress ? String(describing: error) : lastDirectError
            throw error
        }
    }

    /// The original path: usbmuxd discovery + libimobiledevice.
    public func readViaUSBMux(_ device: PhoneDevice, timestamp: Date = Date()) async throws -> BatteryReading {
        let data = try await withRetry(device) { try await self.rawQuery(device, asXML: false) }
        return try BatteryPlistParser.parseIPhone(
            data,
            deviceID: device.udid,
            name: device.name,
            transport: device.transport,
            timestamp: timestamp
        )
    }

    /// One usbmuxd attempt, no retry ladder, under its own deadline.
    ///
    /// The retries in `readViaUSBMux` are worth 6 s of sleeping when the caller
    /// has nothing else to do; inside the race they would just spend the budget,
    /// so the tiered path uses this and lets `PollingPolicy` do the retrying.
    public func readViaUSBMuxOnce(
        _ device: PhoneDevice,
        timestamp: Date = Date(),
        deadline: TimeInterval? = nil
    ) async throws -> BatteryReading {
        let data = try await rawQuery(
            device,
            asXML: false,
            deadline: deadline ?? retryPolicy.deadline
        )
        return try BatteryPlistParser.parseIPhone(
            data,
            deviceID: device.udid,
            name: device.name,
            transport: device.transport,
            timestamp: timestamp
        )
    }

    /// The degraded tier over usbmuxd: `lockdownd_get_value(client,
    /// "com.apple.mobile.battery", NULL, &plist)`.
    ///
    /// No `diagnostics_relay`, so it survives the failure mode where the relay
    /// EOFs on a half-awake phone. Returns a reading with `isPartial == true`.
    public func readPartialViaUSBMux(
        _ device: PhoneDevice,
        timestamp: Date = Date(),
        deadline: TimeInterval? = nil
    ) async throws -> BatteryReading {
        let udid = device.udid
        let transport = device.transport
        let data = try await Self.withDeadline(deadline ?? retryPolicy.deadline) {
            try Self.fetchBatteryDomain(udid: udid, transport: transport)
        }
        return try BatteryPlistParser.parseBatteryDomain(
            data,
            deviceID: device.udid,
            name: device.name,
            transport: device.transport,
            viaDirect: false,
            timestamp: timestamp
        )
    }

    /// The degraded tier straight to a known IP, no usbmuxd. `--direct-only`'s
    /// second chance.
    public func readPartialDirect(
        _ device: PhoneDevice,
        hosts: [String] = [],
        timestamp: Date = Date()
    ) async throws -> BatteryReading {
        var candidates = hosts
        if candidates.isEmpty {
            candidates = await addressBook.dialableAddress(for: device.udid)?.candidates ?? []
        }
        guard !candidates.isEmpty else { throw DirectLockdownError.noAddress(udid: device.udid) }
        return try await directClient.readBatteryDomain(
            udid: device.udid, hosts: candidates, name: device.name, timestamp: timestamp
        )
    }

    /// Read straight from a known IP, no usbmuxd, no fallback. Used by
    /// `tandemctl once --direct-only` and by `probe --compare`.
    public func readDirect(
        _ device: PhoneDevice,
        host: String? = nil,
        hosts: [String] = [],
        timestamp: Date = Date()
    ) async throws -> BatteryReading {
        var candidates: [String] = host.map { [$0] } ?? hosts
        if candidates.isEmpty {
            candidates = await addressBook.dialableAddress(for: device.udid)?.candidates ?? []
        }
        guard !candidates.isEmpty else { throw DirectLockdownError.noAddress(udid: device.udid) }
        return try await directClient.readBattery(
            udid: device.udid,
            hosts: candidates,
            name: device.name,
            timestamp: timestamp
        )
    }

    /// The address we would dial for this phone right now, if any.
    public func knownHost(for udid: String) async -> String? {
        await addressBook.dialableAddress(for: udid)?.host
    }

    /// Every address we would try for this phone, best first.
    public func knownHosts(for udid: String) async -> [String] {
        await addressBook.dialableAddress(for: udid)?.candidates ?? []
    }

    /// Record where usbmuxd currently sees phones. Cheap, and a no-op during a
    /// Bonjour blackout.
    @discardableResult
    public func refreshAddresses() async -> [PhoneAddress] {
        await addressBook.refreshFromUSBMux()
    }

    /// Throw away every remembered address and close any kept-alive session.
    ///
    /// The first half of a Resync (`TandemMonitor.resync()`). Device *names*
    /// are kept in `nameCache`: they cost a lockdown handshake to re-fetch and
    /// a phone does not rename itself between one read and the next — it is the
    /// address, and the socket held open to it, that have gone stale.
    ///
    /// - Returns: the udids whose addresses were forgotten.
    @discardableResult
    public func forgetAddresses() async -> [String] {
        let forgotten = await addressBook.forgetAll()
        closeAllSessions()
        return forgotten
    }

    /// Discovery-first device resolution, for Resync.
    ///
    /// The ordinary `addressableDevices()` is happy to offer a phone that only
    /// the address book remembers, because that is what keeps the direct client
    /// working through a Bonjour blackout. Resync means "look again", so this
    /// asks usbmuxd first — `discoverWithRetry` also runs `refreshFromUSBMux`,
    /// which is where the neighbour table promotes an IPv4 over the Bonjour
    /// link-local — and only falls back to the book if usbmuxd stays blind.
    ///
    /// The retry ladder is deliberately shorter than the default 3 × 3 s: a
    /// person is watching a menu item say "Resyncing…".
    public func rediscover(
        _ policy: PhoneRetryPolicy = PhoneRetryPolicy(attempts: 2, gap: 1)
    ) async -> [PhoneDevice] {
        let found = await discoverWithRetry(policy)
        if !found.isEmpty { return found }
        return await addressableDevices()
    }

    /// Raw plist bytes (XML) for an IORegistry entry — used by `tandemctl dump`
    /// to mint new fixtures.
    public func dump(
        _ device: PhoneDevice,
        entryName: String = PhoneBatterySource.ioRegistryEntryName
    ) async throws -> Data {
        try await withRetry(device) { try await self.rawQuery(device, entryName: entryName, asXML: true) }
    }

    private func withRetry(
        _ device: PhoneDevice,
        _ body: () async throws -> Data
    ) async throws -> Data {
        var lastError: Error = PhoneError.noDevice(udid: device.udid)
        for attempt in 1...retryPolicy.attempts {
            do {
                return try await body()
            } catch let error as PhoneError where error.isTransient {
                lastError = error
                closeSession(device.udid)
                guard attempt < retryPolicy.attempts else { break }
                if retryPolicy.gap > 0 {
                    try? await Task.sleep(for: .seconds(retryPolicy.gap))
                }
                try Task.checkCancellation()
            }
        }
        throw lastError
    }

    /// One query attempt, reusing a kept-alive session when we have one.
    private func rawQuery(
        _ device: PhoneDevice,
        entryName: String = PhoneBatterySource.ioRegistryEntryName,
        asXML: Bool,
        deadline: TimeInterval? = nil
    ) async throws -> Data {
        // Stateless path: no actor state is touched, so the blocking C calls can
        // run off-actor under a deadline without wedging this actor.
        if !keepAlive {
            let udid = device.udid
            let transport = device.transport
            return try await Self.withDeadline(deadline ?? retryPolicy.deadline) {
                let session = try Self.openSession(udid: udid, transport: transport)
                defer { Self.close(session) }
                return try Self.query(session: session, entryName: entryName, asXML: asXML)
            }
        }

        if let session = sessions[device.udid] {
            do {
                return try Self.query(session: session, entryName: entryName, asXML: asXML)
            } catch {
                // Stale socket: drop it and open a fresh session below.
                closeSession(device.udid)
            }
        }

        let session = try Self.openSession(udid: device.udid, transport: device.transport)
        sessions[device.udid] = session
        do {
            return try Self.query(session: session, entryName: entryName, asXML: asXML)
        } catch {
            closeSession(device.udid)
            throw error
        }
    }

    /// Run blocking C work on a detached task and give up on it after `seconds`.
    ///
    /// The work is not cancellable (it is a blocking socket read inside
    /// libimobiledevice), so on timeout we abandon it. That is safe only because
    /// the stateless path owns every handle it touches and frees them itself.
    private static func withDeadline(
        _ seconds: TimeInterval?,
        _ work: @escaping @Sendable () throws -> Data
    ) async throws -> Data {
        guard let seconds, seconds > 0 else {
            return try await Task.detached(priority: .utility) { try work() }.value
        }
        let worker = Task.detached(priority: .utility) { try work() }
        return try await withThrowingTaskGroup(of: Data?.self) { group in
            group.addTask { try await worker.value }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                if let outcome { return outcome }
                throw PhoneError.timedOut(after: seconds)
            }
            throw PhoneError.emptyResponse
        }
    }

    /// How long the kept-alive session for a device has been open, if any.
    public func sessionAge(_ udid: String) -> TimeInterval? {
        sessions[udid].map { Date().timeIntervalSince($0.openedAt) }
    }

    public func closeSession(_ udid: String) {
        guard let session = sessions.removeValue(forKey: udid) else { return }
        Self.close(session)
    }

    public func closeAllSessions() {
        for udid in sessions.keys { closeSession(udid) }
    }

    // MARK: - Events

    /// usbmuxd attach/detach stream. Every access returns a fresh stream; the
    /// underlying `idevice_event_subscribe` is shared and reference counted.
    public nonisolated var events: AsyncStream<PhoneEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let token = PhoneEventHub.shared.add(continuation)
            continuation.onTermination = { _ in PhoneEventHub.shared.remove(token) }
        }
    }

    // MARK: - C bridge

    private static func lookupOptions(for transport: Transport) -> idevice_options {
        switch transport {
        case .wifi:
            // Include USBMUX as well so a device that gains a cable mid-run still
            // resolves, but prefer the network route we discovered it on.
            return idevice_options(
                rawValue: IDEVICE_LOOKUP_NETWORK.rawValue
                    | IDEVICE_LOOKUP_USBMUX.rawValue
                    | IDEVICE_LOOKUP_PREFER_NETWORK.rawValue
            )
        case .usb, .local:
            return idevice_options(
                rawValue: IDEVICE_LOOKUP_USBMUX.rawValue | IDEVICE_LOOKUP_NETWORK.rawValue
            )
        }
    }

    private static func mapLockdownError(_ code: lockdownd_error_t) -> PhoneError {
        switch code {
        case LOCKDOWN_E_INVALID_HOST_ID,
             LOCKDOWN_E_MISSING_HOST_ID,
             LOCKDOWN_E_MISSING_PAIR_RECORD,
             LOCKDOWN_E_INVALID_PAIR_RECORD,
             LOCKDOWN_E_PAIRING_FAILED,
             LOCKDOWN_E_USER_DENIED_PAIRING,
             LOCKDOWN_E_PAIRING_DIALOG_RESPONSE_PENDING,
             LOCKDOWN_E_PASSWORD_PROTECTED:
            return .notPaired(code: code.rawValue)
        default:
            return .unreachable(code: code.rawValue)
        }
    }

    /// `idevice_new_with_options` + `lockdownd_client_new_with_handshake`.
    /// The caller owns both handles.
    private static func openLockdown(
        udid: String,
        transport: Transport
    ) throws -> (device: idevice_t, client: lockdownd_client_t) {
        var device: idevice_t?
        let openResult = udid.withCString { udidPointer in
            idevice_new_with_options(&device, udidPointer, lookupOptions(for: transport))
        }
        guard openResult == IDEVICE_E_SUCCESS, let device else {
            throw PhoneError.noDevice(udid: udid)
        }

        var client: lockdownd_client_t?
        let handshake = clientLabel.withCString { label in
            lockdownd_client_new_with_handshake(device, &client, label)
        }
        guard handshake == LOCKDOWN_E_SUCCESS, let client else {
            idevice_free(device)
            throw mapLockdownError(handshake)
        }
        return (device, client)
    }

    static func fetchDeviceName(udid: String, transport: Transport) throws -> String {
        let (device, client) = try openLockdown(udid: udid, transport: transport)
        defer {
            lockdownd_client_free(client)
            idevice_free(device)
        }
        var node: plist_t?
        let status = "DeviceName".withCString { key in
            lockdownd_get_value(client, nil, key, &node)
        }
        guard status == LOCKDOWN_E_SUCCESS, let node else { throw mapLockdownError(status) }
        defer { plist_free(node) }

        var raw: UnsafeMutablePointer<CChar>?
        plist_get_string_val(node, &raw)
        guard let raw else { throw PhoneError.emptyResponse }
        defer { plist_mem_free(raw) }
        return String(cString: raw)
    }

    /// `lockdownd_get_value(client, "com.apple.mobile.battery", NULL, &plist)`,
    /// re-serialised as a binary plist so `BatteryPlistParser` eats it exactly
    /// like the direct client's XML.
    ///
    /// Four keys come back: `BatteryCurrentCapacity`, `BatteryIsCharging`,
    /// `ExternalConnected`, `FullyCharged`.
    static func fetchBatteryDomain(
        udid: String,
        transport: Transport,
        domain: String = BatteryPlistParser.batteryDomain
    ) throws -> Data {
        let (device, client) = try openLockdown(udid: udid, transport: transport)
        defer {
            lockdownd_client_free(client)
            idevice_free(device)
        }
        var node: plist_t?
        let status = domain.withCString { domainPointer in
            lockdownd_get_value(client, domainPointer, nil, &node)
        }
        guard status == LOCKDOWN_E_SUCCESS, let node else { throw mapLockdownError(status) }
        defer { plist_free(node) }
        guard plist_dict_get_size(node) > 0 else { throw PhoneError.emptyResponse }

        var buffer: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        plist_to_bin(node, &buffer, &length)
        guard let buffer, length > 0 else { throw PhoneError.emptyResponse }
        defer { plist_mem_free(buffer) }
        return Data(bytes: buffer, count: Int(length))
    }

    /// The exact sequence `idevicediagnostics` performs, up to the point where
    /// the relay is ready for queries.
    private static func openSession(udid: String, transport: Transport) throws -> Session {
        let (device, lockdown) = try openLockdown(udid: udid, transport: transport)

        var service: lockdownd_service_descriptor_t?
        var startResult = diagnosticsService.withCString { identifier in
            lockdownd_start_service(lockdown, identifier, &service)
        }
        if startResult == LOCKDOWN_E_INVALID_SERVICE {
            startResult = legacyDiagnosticsService.withCString { identifier in
                lockdownd_start_service(lockdown, identifier, &service)
            }
        }
        // The CLI frees the lockdown client as soon as the service port is known.
        lockdownd_client_free(lockdown)

        guard startResult == LOCKDOWN_E_SUCCESS, let service, service.pointee.port > 0 else {
            if let service { lockdownd_service_descriptor_free(service) }
            idevice_free(device)
            throw PhoneError.serviceFailed(code: startResult.rawValue)
        }

        var relay: diagnostics_relay_client_t?
        let relayResult = diagnostics_relay_client_new(device, service, &relay)
        guard relayResult == DIAGNOSTICS_RELAY_E_SUCCESS, let relay else {
            lockdownd_service_descriptor_free(service)
            idevice_free(device)
            throw PhoneError.serviceFailed(code: relayResult.rawValue)
        }

        return Session(
            device: device,
            service: service,
            relay: relay,
            openedAt: Date(),
            transport: transport
        )
    }

    private static func query(session: Session, entryName: String, asXML: Bool) throws -> Data {
        var node: plist_t?
        // entry_class is "" — the CLI passes an empty string, never NULL.
        let queryResult = entryName.withCString { name in
            "".withCString { entryClass in
                diagnostics_relay_query_ioregistry_entry(session.relay, name, entryClass, &node)
            }
        }
        guard queryResult == DIAGNOSTICS_RELAY_E_SUCCESS, let node else {
            throw PhoneError.queryFailed(code: queryResult.rawValue)
        }
        defer { plist_free(node) }

        // An absent entry comes back as an empty dict rather than an error.
        if plist_dict_get_size(node) == 0 { throw PhoneError.emptyResponse }

        var buffer: UnsafeMutablePointer<CChar>?
        var length: UInt32 = 0
        if asXML {
            plist_to_xml(node, &buffer, &length)
        } else {
            plist_to_bin(node, &buffer, &length)
        }
        guard let buffer, length > 0 else { throw PhoneError.emptyResponse }
        defer { plist_mem_free(buffer) }
        return Data(bytes: buffer, count: Int(length))
    }

    private static func close(_ session: Session) {
        diagnostics_relay_goodbye(session.relay)
        diagnostics_relay_client_free(session.relay)
        lockdownd_service_descriptor_free(session.service)
        idevice_free(session.device)
    }
}

// MARK: - Event fan-out

/// Single process-wide `idevice_event_subscribe` registration, fanned out to
/// however many `AsyncStream`s are alive.
///
/// The C callback is a bare function pointer, so this state has to be global.
private final class PhoneEventHub: @unchecked Sendable {
    static let shared = PhoneEventHub()

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<PhoneEvent>.Continuation] = [:]
    private var subscribed = false

    func add(_ continuation: AsyncStream<PhoneEvent>.Continuation) -> UUID {
        let token = UUID()
        lock.lock()
        continuations[token] = continuation
        let needsSubscribe = !subscribed
        if needsSubscribe { subscribed = true }
        lock.unlock()

        if needsSubscribe {
            let status = idevice_event_subscribe({ event, _ in
                guard let event = event?.pointee else { return }
                let udid = event.udid.map { String(cString: $0) } ?? ""
                let transport: Transport = (event.conn_type == CONNECTION_NETWORK) ? .wifi : .usb
                let mapped: PhoneEvent
                switch event.event {
                case IDEVICE_DEVICE_ADD: mapped = .attached(udid: udid, transport: transport)
                case IDEVICE_DEVICE_REMOVE: mapped = .detached(udid: udid)
                default: mapped = .paired(udid: udid)
                }
                PhoneEventHub.shared.dispatch(mapped)
            }, nil)
            if status != IDEVICE_E_SUCCESS {
                lock.lock()
                subscribed = false
                lock.unlock()
                continuation.finish()
            }
        }
        return token
    }

    func remove(_ token: UUID) {
        lock.lock()
        continuations.removeValue(forKey: token)
        let shouldUnsubscribe = continuations.isEmpty && subscribed
        if shouldUnsubscribe { subscribed = false }
        lock.unlock()
        if shouldUnsubscribe {
            idevice_event_unsubscribe()
        }
    }

    fileprivate func dispatch(_ event: PhoneEvent) {
        lock.lock()
        let targets = Array(continuations.values)
        lock.unlock()
        for target in targets { target.yield(event) }
    }
}
