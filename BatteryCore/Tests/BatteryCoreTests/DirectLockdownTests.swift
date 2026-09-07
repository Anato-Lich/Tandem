import Foundation
import Testing
@testable import BatteryCore

// MARK: - Synthetic fixtures

/// A pair record with the right shape but no real key material. Nothing here is
/// fed to OpenSSL; the parser never validates the PEM, it only carries it.
enum SyntheticPairRecord {
    static let hostID = "0F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0"
    static let systemBUID = "11112222-3333-4444-5555-666677778888"
    static let hostCertificate = "-----BEGIN CERTIFICATE-----\nZmFrZWhvc3RjZXJ0\n-----END CERTIFICATE-----\n"
    static let hostPrivateKey = "-----BEGIN RSA PRIVATE KEY-----\nZmFrZWhvc3RrZXk=\n-----END RSA PRIVATE KEY-----\n"

    /// The `<data>` shape usbmuxd actually stores: PEM bytes in a data field.
    static func plist(dataValued: Bool = true) throws -> Data {
        func value(_ text: String) -> Any { dataValued ? Data(text.utf8) : text }
        let dictionary: [String: Any] = [
            "HostID": hostID,
            "SystemBUID": systemBUID,
            "HostCertificate": value(hostCertificate),
            "HostPrivateKey": value(hostPrivateKey),
            "DeviceCertificate": value("-----BEGIN CERTIFICATE-----\nZGV2aWNl\n-----END CERTIFICATE-----\n"),
            "RootCertificate": value("-----BEGIN CERTIFICATE-----\ncm9vdA==\n-----END CERTIFICATE-----\n"),
            "EscrowBag": Data([0xDE, 0xAD, 0xBE, 0xEF]),
            "WiFiMACAddress": "aa:bb:cc:dd:ee:ff",
        ]
        return try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
    }
}

/// A reading that does not depend on any fixture file.
func makeReading(
    percent: Int = 50,
    transport: Transport = .wifi,
    viaDirect: Bool = false
) -> BatteryReading {
    BatteryReading(
        deviceID: "udid", kind: .iphone, name: "iPhone", percent: percent,
        isCharging: true, externalConnected: true, fullyCharged: false,
        rawCurrentMAh: 2000, rawMaxMAh: 4000, designMAh: 4000, voltageMV: 4000,
        instantAmperageMA: 1000, batteryPowerW: 4.0, temperatureC: 28.9, cycleCount: 10,
        timestamp: referenceDate, transport: transport, viaDirect: viaDirect
    )
}

// MARK: - Framing

@Suite("Lockdown framing")
struct LockdownWireTests {

    @Test("A request round-trips through the 4-byte big-endian length prefix")
    func roundTrip() throws {
        let message: [String: Any] = [
            "Label": "tandem",
            "Request": "StartSession",
            "HostID": SyntheticPairRecord.hostID,
        ]
        let framed = try LockdownWire.encode(message)

        // The prefix is the payload length, big-endian, and is not counted in itself.
        let length = try LockdownWire.payloadLength(from: framed.prefix(4))
        #expect(length == framed.count - 4)
        #expect(Array(framed.prefix(4)) == [
            UInt8((length >> 24) & 0xFF), UInt8((length >> 16) & 0xFF),
            UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF),
        ])

        let decoded = try LockdownWire.decodeFramed(framed)
        #expect(decoded["Request"] as? String == "StartSession")
        #expect(decoded["Label"] as? String == "tandem")
        #expect(decoded["HostID"] as? String == SyntheticPairRecord.hostID)
    }

    @Test("We send XML but decode either format, because the relay answers binary")
    func decodesBothPlistFormats() throws {
        let payload = ["Status": "Success"]
        for format in [PropertyListSerialization.PropertyListFormat.xml, .binary] {
            let body = try PropertyListSerialization.data(fromPropertyList: payload, format: format, options: 0)
            let framed = LockdownWire.header(for: body.count) + body
            #expect(try LockdownWire.decodeFramed(framed)["Status"] as? String == "Success")
        }
        // And what we produce is XML, as lockdownd expects from a client.
        let sent = try LockdownWire.encode(payload)
        #expect(String(decoding: sent.dropFirst(4).prefix(5), as: UTF8.self) == "<?xml")
    }

    @Test("Nonsense lengths are refused instead of trusted")
    func rejectsBadLengths() throws {
        #expect(throws: DirectLockdownError.self) {
            try LockdownWire.payloadLength(from: Data([0, 0, 0]))
        }
        #expect(throws: DirectLockdownError.self) {
            try LockdownWire.payloadLength(from: Data([0, 0, 0, 0]))
        }
        // 0xFFFFFFFF would be a 4 GB allocation on a desynchronised stream.
        #expect(throws: DirectLockdownError.self) {
            try LockdownWire.payloadLength(from: Data([0xFF, 0xFF, 0xFF, 0xFF]))
        }
    }

    @Test("A truncated payload names the step it failed at")
    func truncatedPayload() throws {
        let framed = try LockdownWire.encode(["Request": "QueryType"])
        let error = #expect(throws: DirectLockdownError.self) {
            try LockdownWire.decodeFramed(framed.dropLast(10))
        }
        #expect(error?.step == "read payload")
    }

    @Test("A non-dictionary payload is a protocol error, not a crash")
    func rejectsNonDictionary() throws {
        let body = try PropertyListSerialization.data(fromPropertyList: [1, 2, 3], format: .binary, options: 0)
        #expect(throws: DirectLockdownError.self) {
            try LockdownWire.decodeFramed(LockdownWire.header(for: body.count) + body)
        }
    }

    @Test("The IORegistry reply is unwrapped down to the entry dictionary")
    func extractsIORegistry() throws {
        let reply: [String: Any] = [
            "Status": "Success",
            "Diagnostics": ["IORegistry": ["CurrentCapacity": 88, "MaxCapacity": 100]],
        ]
        let data = try DirectLockdownClient.extractIORegistry(reply)
        let entry = try BatteryPlistParser.rootDictionary(from: data)
        #expect(BatteryPlistParser.normalizedInt(entry["CurrentCapacity"]) == 88)

        #expect(throws: DirectLockdownError.self) {
            try DirectLockdownClient.extractIORegistry(["Status": "Failure"])
        }
        // An absent entry comes back as an empty dict, exactly like the C path.
        #expect(throws: DirectLockdownError.self) {
            try DirectLockdownClient.extractIORegistry([
                "Status": "Success", "Diagnostics": ["IORegistry": [String: Any]()],
            ])
        }
    }
}

// MARK: - Pair record

@Suite("Pair record parsing")
struct PairRecordTests {

    @Test("A usbmuxd-shaped record parses, data-valued or string-valued")
    func parsesBothValueShapes() throws {
        for dataValued in [true, false] {
            let record = try PairRecord(plistData: SyntheticPairRecord.plist(dataValued: dataValued))
            #expect(record.hostID == SyntheticPairRecord.hostID)
            #expect(record.systemBUID == SyntheticPairRecord.systemBUID)
            #expect(String(decoding: record.hostCertificate, as: UTF8.self) == SyntheticPairRecord.hostCertificate)
            #expect(String(decoding: record.hostPrivateKey, as: UTF8.self) == SyntheticPairRecord.hostPrivateKey)
            #expect(record.wifiMACAddress == "aa:bb:cc:dd:ee:ff")
            #expect(record.escrowBag == Data([0xDE, 0xAD, 0xBE, 0xEF]))
            #expect(record.rootCertificate != nil)
        }
    }

    @Test("Every required key is required")
    func rejectsIncompleteRecords() throws {
        for missing in ["HostID", "SystemBUID", "HostCertificate", "HostPrivateKey"] {
            var plist = try PropertyListSerialization.propertyList(
                from: SyntheticPairRecord.plist(), options: [], format: nil
            ) as! [String: Any]
            plist.removeValue(forKey: missing)
            #expect(throws: DirectLockdownError.self) { try PairRecord(plist: plist) }
        }
        #expect(throws: DirectLockdownError.self) {
            try PairRecord(plistData: Data("not a plist at all".utf8))
        }
    }

    @Test("Printing a pair record never prints the private key")
    func descriptionRedactsTheKey() throws {
        let record = try PairRecord(plistData: SyntheticPairRecord.plist())
        let text = record.description
        #expect(!text.contains("PRIVATE KEY"))
        #expect(!text.contains("ZmFrZWhvc3RrZXk="))
        #expect(text.contains("redacted"))
        #expect(text.contains(SyntheticPairRecord.hostID))
    }
}

// MARK: - Address book

@Suite("Phone address book")
struct PhoneAddressBookTests {

    private func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandem-addresses-\(UUID().uuidString)", isDirectory: true)
    }

    @Test("Addresses survive a new process reading the same file")
    func persistsAcrossInstances() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let book = PhoneAddressBook(directory: directory)
        let recorded = await book.record(udid: "UDID-A", host: "192.0.2.10", at: referenceDate)
        #expect(recorded.host == "192.0.2.10")
        #expect(await book.lastWriteError == nil)
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("addresses.json").path))

        let reopened = PhoneAddressBook(directory: directory)
        let reloaded = await reopened.address(for: "UDID-A")
        #expect(reloaded?.host == "192.0.2.10")
        #expect(reloaded?.lastSeen == referenceDate)
        #expect(await reopened.host(for: "UDID-A") == "192.0.2.10")
        #expect(await reopened.address(for: "UDID-B") == nil)
    }

    @Test("A missing file reads as empty rather than throwing")
    func missingFileIsEmpty() async throws {
        let book = PhoneAddressBook(directory: temporaryDirectory())
        #expect(await book.all().isEmpty)
        #expect(await book.address(for: "anything") == nil)
    }

    @Test("Re-recording moves the address and keeps the name; forget removes it")
    func updatesAndForgets() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = PhoneAddressBook(directory: directory)

        await book.record(udid: "UDID-A", host: "192.0.2.10", name: "iPhone", at: referenceDate)
        // A later sighting with no name must not wipe the name we already have.
        let moved = await book.record(udid: "UDID-A", host: "192.0.2.20", at: referenceDate.addingTimeInterval(60))
        #expect(moved.host == "192.0.2.20")
        #expect(moved.name == "iPhone")
        #expect(await book.all().count == 1)

        await book.recordName("Renamed", for: "UDID-A")
        #expect(await book.address(for: "UDID-A")?.name == "Renamed")

        await book.forget("UDID-A")
        #expect(await book.address(for: "UDID-A") == nil)
        #expect(await PhoneAddressBook(directory: directory).all().isEmpty)
    }

    @Test("Candidates are ordered best-first and de-duplicated")
    func ordersCandidates() {
        let address = PhoneAddress(
            udid: "u",
            host: "192.0.2.10",
            alternateHosts: ["fe80::1%en0", "192.0.2.10"]
        )
        #expect(address.candidates == ["192.0.2.10", "fe80::1%en0"])
        #expect(PhoneAddress(udid: "u", host: "h").candidates == ["h"])
    }

    @Test("An IPv6-only entry is promoted to IPv4 when the kernel knows one")
    func promotesIPv4() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandem-addresses-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let book = PhoneAddressBook(directory: directory)

        // No neighbour will ever match this, so the entry must come back intact
        // rather than being mangled or dropped.
        await book.record(udid: "UDID-A", host: "fe80::dead:beef%lo0", at: referenceDate)
        let dialable = await book.dialableAddress(for: "UDID-A")
        #expect(dialable?.host == "fe80::dead:beef%lo0")
        #expect(dialable?.candidates == ["fe80::dead:beef%lo0"])

        // An IPv4 entry is never touched.
        await book.record(udid: "UDID-B", host: "192.0.2.10", at: referenceDate)
        #expect(await book.dialableAddress(for: "UDID-B")?.host == "192.0.2.10")
        #expect(await book.dialableAddress(for: "UDID-C") == nil)
    }

    @Test("The neighbour tables parse without throwing and yield sane entries")
    func readsNeighbourTables() {
        // Nothing is asserted about the contents — this machine's caches are
        // whatever they are — only that the sockaddr walk stays in bounds and
        // produces well-formed values.
        for family in [AF_INET, AF_INET6] {
            for entry in NeighborTable.entries(family: family) {
                #expect(!entry.address.isEmpty)
                #expect(entry.hardwareAddress.split(separator: ":").count == 6)
                #expect(entry.hardwareAddress == entry.hardwareAddress.lowercased())
            }
        }
        #expect(NeighborTable.ipv4Peer(of: "fe80::dead:beef%lo0") == nil)
    }

    @Test("Age is measured from the recorded sighting")
    func reportsAge() {
        let address = PhoneAddress(udid: "u", host: "h", lastSeen: referenceDate)
        #expect(address.age(at: referenceDate.addingTimeInterval(90)) == 90)
    }

    @Test("usbmuxd's conn_data sockaddr decodes to a dialable literal")
    func decodesSockaddrs() throws {
        // BSD sockaddr_in: sin_len, sin_family, sin_port, sin_addr.
        var ipv4 = [UInt8](repeating: 0, count: 16)
        ipv4[0] = 16
        ipv4[1] = UInt8(AF_INET)
        ipv4[2] = 0xF2; ipv4[3] = 0x7E          // port 62078, unused by the decoder
        ipv4[4] = 192; ipv4[5] = 0; ipv4[6] = 2; ipv4[7] = 10
        #expect(ipv4.withUnsafeBytes { PhoneAddressBook.decodeHost($0.baseAddress!) } == "192.0.2.10")

        // BSD sockaddr_in6: len, family, port, flowinfo, addr(16), scope_id.
        var ipv6 = [UInt8](repeating: 0, count: 28)
        ipv6[0] = 28
        ipv6[1] = UInt8(AF_INET6)
        ipv6[8] = 0x20; ipv6[9] = 0x01; ipv6[10] = 0x0d; ipv6[11] = 0xb8
        ipv6[23] = 0x01
        #expect(ipv6.withUnsafeBytes { PhoneAddressBook.decodeHost($0.baseAddress!) } == "2001:db8::1")

        // A family we do not understand yields nothing rather than garbage.
        var junk = [UInt8](repeating: 0, count: 16)
        junk[0] = 16
        junk[1] = 99
        #expect(junk.withUnsafeBytes { PhoneAddressBook.decodeHost($0.baseAddress!) } == nil)
    }

    @Test("A link-local address carries its interface scope, or it is unusable")
    func scopesLinkLocalAddresses() throws {
        var bytes = [UInt8](repeating: 0, count: 28)
        bytes[0] = 28
        bytes[1] = UInt8(AF_INET6)
        bytes[8] = 0xfe; bytes[9] = 0x80
        bytes[23] = 0x2c
        bytes[24] = 1                    // sin6_scope_id, little-endian: interface 1
        let host = bytes.withUnsafeBytes { PhoneAddressBook.decodeHost($0.baseAddress!) }
        #expect(host?.hasPrefix("fe80::2c%") == true)
    }
}

// MARK: - Fallback decision

/// Records what a `DirectFirstReader` asked for, so the decision can be checked
/// without a phone, a socket or usbmuxd.
actor FakeTransport {
    enum Behaviour: Sendable { case succeeds, fails }

    var directBehaviour: Behaviour
    var fallbackBehaviour: Behaviour
    var discoverableHost: String?

    private(set) var directHosts: [String] = []
    private(set) var fallbackCalls = 0
    private(set) var lookupCalls = 0

    init(direct: Behaviour, fallback: Behaviour, discoverableHost: String? = nil) {
        self.directBehaviour = direct
        self.fallbackBehaviour = fallback
        self.discoverableHost = discoverableHost
    }

    func direct(_ address: PhoneAddress) throws -> BatteryReading {
        directHosts.append(contentsOf: address.candidates)
        guard directBehaviour == .succeeds else {
            throw DirectLockdownError.timedOut(step: "connect \(address.host):62078", after: 8)
        }
        return makeReading(percent: 71, viaDirect: true)
    }

    func fallback() throws -> BatteryReading {
        fallbackCalls += 1
        guard fallbackBehaviour == .succeeds else { throw PhoneError.noDevice(udid: "udid") }
        return makeReading(percent: 42)
    }

    func lookup() -> String? {
        lookupCalls += 1
        return discoverableHost
    }
}

@Suite("Direct-first fallback logic")
struct DirectFirstReaderTests {

    private let cached = PhoneAddress(udid: "udid", host: "192.0.2.10", lastSeen: referenceDate)

    private func run(
        _ reader: DirectFirstReader,
        address: PhoneAddress?,
        now: Date = referenceDate,
        transport: FakeTransport
    ) async throws -> DirectFirstOutcome {
        try await reader.read(
            cachedAddress: address,
            now: now,
            direct: { try await transport.direct($0) },
            fallback: { try await transport.fallback() },
            lookupAddress: { await transport.lookup() }
        )
    }

    @Test("A working direct path never touches usbmuxd")
    func directWins() async throws {
        let transport = FakeTransport(direct: .succeeds, fallback: .succeeds)
        let outcome = try await run(DirectFirstReader(), address: cached, transport: transport)

        #expect(outcome.usedDirect)
        #expect(outcome.reading.percent == 71)
        #expect(outcome.reading.viaDirect)
        #expect(outcome.directError == nil)
        #expect(await transport.directHosts == ["192.0.2.10"])
        #expect(await transport.fallbackCalls == 0)
    }

    @Test("A failed direct attempt falls back and refreshes the cached address")
    func fallsBackAndRefreshes() async throws {
        let transport = FakeTransport(direct: .fails, fallback: .succeeds, discoverableHost: "192.0.2.20")
        let outcome = try await run(DirectFirstReader(), address: cached, transport: transport)

        #expect(!outcome.usedDirect)
        #expect(outcome.reading.percent == 42)
        #expect(outcome.refreshedHost == "192.0.2.20")
        // The failure is reported, not swallowed, and it names the step.
        #expect(outcome.directError?.contains("connect 192.0.2.10:62078") == true)
        #expect(await transport.fallbackCalls == 1)
        #expect(await transport.lookupCalls == 1)
    }

    @Test("With no cached address we go straight to usbmuxd")
    func noAddressMeansFallback() async throws {
        let transport = FakeTransport(direct: .succeeds, fallback: .succeeds, discoverableHost: "192.0.2.10")
        let outcome = try await run(DirectFirstReader(), address: nil, transport: transport)

        #expect(!outcome.usedDirect)
        #expect(outcome.directError == "no cached address")
        #expect(await transport.directHosts.isEmpty)
        #expect(outcome.refreshedHost == "192.0.2.10")
    }

    @Test("An address older than the limit is not dialled")
    func expiredAddressIsSkipped() async throws {
        let transport = FakeTransport(direct: .succeeds, fallback: .succeeds)
        let reader = DirectFirstReader(maximumAddressAge: 300)
        #expect(reader.shouldTryDirect(cached, now: referenceDate.addingTimeInterval(299)))
        #expect(!reader.shouldTryDirect(cached, now: referenceDate.addingTimeInterval(301)))

        let outcome = try await run(
            reader, address: cached, now: referenceDate.addingTimeInterval(3600), transport: transport
        )
        #expect(!outcome.usedDirect)
        #expect(await transport.directHosts.isEmpty)
        #expect(outcome.directError?.contains("300 s") == true)
    }

    @Test("useDirect: false reproduces the pre-direct behaviour exactly")
    func directDisabled() async throws {
        let transport = FakeTransport(direct: .succeeds, fallback: .succeeds)
        let outcome = try await run(
            DirectFirstReader(useDirect: false), address: cached, transport: transport
        )
        #expect(!outcome.usedDirect)
        #expect(outcome.directError == nil)
        #expect(await transport.directHosts.isEmpty)
        #expect(await transport.fallbackCalls == 1)
    }

    @Test("directOnly re-raises the direct failure instead of falling back")
    func directOnlyPropagatesTheRealError() async throws {
        let transport = FakeTransport(direct: .fails, fallback: .succeeds)
        let reader = DirectFirstReader(directOnly: true)

        await #expect(throws: DirectLockdownError.self) {
            try await run(reader, address: cached, transport: transport)
        }
        #expect(await transport.fallbackCalls == 0)
        #expect(await transport.directHosts.count == 1)
    }

    @Test("directOnly with nothing to dial says so")
    func directOnlyWithoutAnAddress() async throws {
        let transport = FakeTransport(direct: .succeeds, fallback: .succeeds)
        let error = await #expect(throws: DirectLockdownError.self) {
            try await run(DirectFirstReader(directOnly: true), address: nil, transport: transport)
        }
        #expect(error == .noAddress(udid: ""))
        #expect(await transport.fallbackCalls == 0)
    }

    @Test("When both paths fail, the caller sees the usbmuxd error")
    func bothFail() async throws {
        let transport = FakeTransport(direct: .fails, fallback: .fails)
        await #expect(throws: PhoneError.self) {
            try await run(DirectFirstReader(), address: cached, transport: transport)
        }
    }
}

// MARK: - Codable compatibility

@Suite("viaDirect stays compatible with snapshots written before it existed")
struct ViaDirectCodableTests {

    @Test("A reading JSON with no viaDirect key decodes as false")
    func decodesLegacyJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(makeReading(viaDirect: true))
        ) as! [String: Any]
        #expect(object["viaDirect"] as? Bool == true)
        object.removeValue(forKey: "viaDirect")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            BatteryReading.self, from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(!decoded.viaDirect)
        #expect(decoded.percent == 50)
    }

    @Test("viaDirect survives a round trip and does not disturb equality")
    func roundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for flag in [true, false] {
            let reading = makeReading(viaDirect: flag)
            let decoded = try decoder.decode(BatteryReading.self, from: try encoder.encode(reading))
            #expect(decoded == reading)
            #expect(decoded.viaDirect == flag)
        }
        #expect(makeReading(viaDirect: true) != makeReading(viaDirect: false))
    }
}
