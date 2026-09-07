import Foundation
import CLibimobiledevice
#if canImport(Darwin)
import Darwin
#endif

/// The last IP we saw a phone at, and when.
public struct PhoneAddress: Sendable, Codable, Equatable {
    public var udid: String
    /// The address to dial first. A numeric literal — IPv4 dotted quad, or IPv6
    /// with a `%interface` scope when it is link-local. IPv4 is preferred when
    /// we know one, because that is the address that survives a phone nap; see
    /// `NeighborTable`.
    public var host: String
    /// Other addresses for the same phone, tried in order if `host` fails.
    /// Absent from files written before this existed.
    public var alternateHosts: [String]?
    public var lastSeen: Date
    /// The lockdown `DeviceName`, when we have managed to ask for it. Kept here
    /// so a direct-only read during a blackout can still label the phone.
    public var name: String?

    public init(
        udid: String,
        host: String,
        alternateHosts: [String]? = nil,
        lastSeen: Date = Date(),
        name: String? = nil
    ) {
        self.udid = udid
        self.host = host
        self.alternateHosts = alternateHosts
        self.lastSeen = lastSeen
        self.name = name
    }

    /// Everything worth dialling, best first, de-duplicated.
    public var candidates: [String] {
        var seen = Set<String>()
        return ([host] + (alternateHosts ?? [])).filter { seen.insert($0).inserted }
    }

    public func age(at now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(lastSeen)
    }
}

/// Remembers where each phone lives, so `DirectLockdownClient` has somewhere to
/// dial during a usbmuxd blackout.
///
/// usbmuxd only tells us a device's address while it can see the device — which
/// is exactly when we do not need it. So every time the libimobiledevice path
/// *does* see the phone, the address is captured here and written to JSON, and
/// the direct client reads it back later when Bonjour has gone quiet.
///
/// Nothing secret lives in this file: a UDID, an IP and a timestamp.
public actor PhoneAddressBook {

    public static let fileName = "addresses.json"

    /// `~/Library/Application Support/Tandem`.
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Tandem", isDirectory: true)
    }

    public nonisolated let url: URL
    private var entries: [String: PhoneAddress]?
    /// Set when a write fails, so a caller can say so instead of guessing.
    public private(set) var lastWriteError: String?

    /// - Parameter directory: where `addresses.json` lives.
    public init(directory: URL = PhoneAddressBook.defaultDirectory) {
        self.url = directory.appendingPathComponent(PhoneAddressBook.fileName)
    }

    /// Point at an exact file rather than a directory.
    public init(fileURL: URL) {
        self.url = fileURL
    }

    // MARK: - Lookup

    public func address(for udid: String) -> PhoneAddress? {
        loaded()[udid]
    }

    public func host(for udid: String) -> String? {
        loaded()[udid]?.host
    }

    /// `address(for:)`, but with an IPv4 promoted ahead of an IPv6 link-local
    /// whenever the kernel's neighbour caches can name one for the same
    /// hardware — see `NeighborTable` for why that matters.
    ///
    /// The promotion is persisted, so it is looked up once and then read back
    /// from the file even after the neighbour entry expires.
    public func dialableAddress(for udid: String) -> PhoneAddress? {
        guard var entry = loaded()[udid] else { return nil }
        guard entry.host.contains(":"), let ipv4 = NeighborTable.ipv4Peer(of: entry.host) else {
            return entry
        }
        var alternates = [entry.host] + (entry.alternateHosts ?? [])
        alternates.removeAll { $0 == ipv4 }
        entry.host = ipv4
        entry.alternateHosts = alternates
        var current = loaded()
        current[udid] = entry
        entries = current
        persist(current)
        return entry
    }

    public func all() -> [PhoneAddress] {
        loaded().values.sorted { $0.udid < $1.udid }
    }

    // MARK: - Mutation

    /// A `nil` name keeps whatever name is already on file.
    @discardableResult
    public func record(
        udid: String,
        host: String,
        alternateHosts: [String]? = nil,
        name: String? = nil,
        at date: Date = Date()
    ) -> PhoneAddress {
        var current = loaded()
        let entry = PhoneAddress(
            udid: udid,
            host: host,
            alternateHosts: alternateHosts,
            lastSeen: date,
            name: name ?? current[udid]?.name
        )
        current[udid] = entry
        entries = current
        persist(current)
        return entry
    }

    /// Remember a device name without claiming to have seen it just now.
    public func recordName(_ name: String, for udid: String) {
        var current = loaded()
        guard var entry = current[udid], entry.name != name else { return }
        entry.name = name
        current[udid] = entry
        entries = current
        persist(current)
    }

    public func forget(_ udid: String) {
        var current = loaded()
        guard current.removeValue(forKey: udid) != nil else { return }
        entries = current
        persist(current)
    }

    /// Forget every remembered address, and say which ones went.
    ///
    /// This is what the menu's Resync does first: with the file empty the next
    /// read has nothing to dial and has to go through discovery — usbmuxd's
    /// device list and, inside `refreshFromUSBMux`, the neighbour table — which
    /// is the whole point of asking for a resync.
    @discardableResult
    public func forgetAll() -> [String] {
        let current = loaded()
        guard !current.isEmpty else { return [] }
        let udids = current.keys.sorted()
        entries = [:]
        persist([:])
        return udids
    }

    /// Ask usbmuxd for every device it can see right now and record the network
    /// ones. A no-op during a blackout, which is fine — the point is to catch
    /// the address while the phone *is* visible.
    @discardableResult
    public func refreshFromUSBMux(now: Date = Date()) -> [PhoneAddress] {
        let found = PhoneAddressBook.scanUSBMux()
        guard !found.isEmpty else { return [] }
        var current = loaded()
        var updated: [PhoneAddress] = []
        for (udid, host) in found {
            // usbmuxd reports whichever address Bonjour resolved, which on this
            // network is the IPv6 link-local — useless while the phone naps. If
            // the neighbour caches can name an IPv4 for the same hardware,
            // promote that and keep the original as a fallback.
            var primary = host
            var alternates: [String] = []
            if host.contains(":"), let ipv4 = NeighborTable.ipv4Peer(of: host) {
                primary = ipv4
                alternates = [host]
            }
            let entry = PhoneAddress(
                udid: udid,
                host: primary,
                alternateHosts: alternates.isEmpty ? nil : alternates,
                lastSeen: now,
                name: current[udid]?.name
            )
            current[udid] = entry
            updated.append(entry)
        }
        entries = current
        persist(current)
        return updated
    }

    // MARK: - Persistence

    private func loaded() -> [String: PhoneAddress] {
        if let entries { return entries }
        let decoded: [String: PhoneAddress]
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            decoded = (try? decoder.decode([String: PhoneAddress].self, from: data)) ?? [:]
        } else {
            decoded = [:]
        }
        entries = decoded
        return decoded
    }

    private func persist(_ value: [String: PhoneAddress]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            lastWriteError = nil
        } catch {
            lastWriteError = error.localizedDescription
        }
    }

    // MARK: - usbmuxd address decoding

    /// Every network-visible device usbmuxd currently lists, as `udid -> host`.
    public static func scanUSBMux() -> [String: String] {
        var list: UnsafeMutablePointer<idevice_info_t?>?
        var count: Int32 = 0
        guard idevice_get_device_list_extended(&list, &count) == IDEVICE_E_SUCCESS, let list else {
            return [:]
        }
        defer { idevice_device_list_extended_free(list) }

        var result: [String: String] = [:]
        for index in 0..<Int(count) {
            guard let info = list[index]?.pointee,
                  info.conn_type == CONNECTION_NETWORK,
                  let udidPointer = info.udid,
                  let connData = info.conn_data,
                  let host = decodeHost(connData)
            else { continue }
            result[String(cString: udidPointer)] = host
        }
        return result
    }

    /// `idevice_info.conn_data` for a `CONNECTION_NETWORK` device is the raw
    /// `sockaddr` usbmuxd got from the Bonjour record — on macOS a BSD one, so
    /// byte 0 is `sa_len` and byte 1 is `sa_family`. Some builds hand back the
    /// Linux layout instead (16-bit family at offset 0, no length byte), so both
    /// are probed.
    ///
    /// Returns a numeric literal suitable for `getaddrinfo(AI_NUMERICHOST)`.
    public static func decodeHost(_ pointer: UnsafeRawPointer) -> String? {
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        let bsdFamily = bytes[1]
        if let host = decodeHost(bytes, family: bsdFamily, addressOffset: bsdFamily == UInt8(AF_INET) ? 4 : 8) {
            return host
        }
        // Linux-style: sa_family_t is a 16-bit little-endian value at offset 0.
        let linuxFamily = bytes[0]
        guard bytes[1] == 0 else { return nil }
        return decodeHost(bytes, family: linuxFamily, addressOffset: linuxFamily == UInt8(AF_INET) ? 4 : 8)
    }

    private static func decodeHost(
        _ bytes: UnsafePointer<UInt8>,
        family: UInt8,
        addressOffset: Int
    ) -> String? {
        switch Int32(family) {
        case AF_INET:
            var address = in_addr()
            memcpy(&address, bytes + addressOffset, MemoryLayout<in_addr>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                return nil
            }
            return text(from: buffer)
        case AF_INET6:
            var address = in6_addr()
            memcpy(&address, bytes + addressOffset, MemoryLayout<in6_addr>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
                return nil
            }
            guard var host = text(from: buffer) else { return nil }
            // A link-local address is useless without the interface it is local to.
            if host.hasPrefix("fe80:") {
                var scope: UInt32 = 0
                memcpy(&scope, bytes + addressOffset + MemoryLayout<in6_addr>.size, MemoryLayout<UInt32>.size)
                if scope == 0 {
                    // sockaddr_in6 puts sin6_scope_id last: len,fam,port,flow,addr,scope.
                    memcpy(&scope, bytes + 24, MemoryLayout<UInt32>.size)
                }
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if scope != 0, if_indextoname(scope, &name) != nil, let interface = text(from: name) {
                    host += "%" + interface
                }
            }
            return host
        default:
            return nil
        }
    }

    private static func text(from buffer: [CChar]) -> String? {
        let string = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return string.isEmpty ? nil : string
    }
}
