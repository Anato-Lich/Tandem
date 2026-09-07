import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The kernel's ARP and NDP caches, read straight out of the routing table.
///
/// Why this is here: usbmuxd hands us whichever address Bonjour resolved, and on
/// this network that is the phone's **IPv6 link-local** — which is exactly the
/// address that stops answering while the phone sleeps. Neighbour Discovery
/// needs the phone's own stack to reply to a solicitation; ARP for its IPv4 is
/// answered by the Wi-Fi chip (or the AP) while the OS is asleep. Measured here:
/// during a blackout, connect to `fe80::…%en0:62078` times out at 8 s every
/// time, while the same phone's IPv4 accepts the connection in 10 ms.
///
/// So we take the link-local usbmuxd gave us, find its hardware address in the
/// NDP cache, and look that hardware address up in the ARP cache to learn the
/// IPv4. Everything is `sysctl(NET_RT_FLAGS)`; nothing shells out to `arp(8)`.
public enum NeighborTable {

    public struct Entry: Sendable, Equatable {
        /// A numeric literal, with `%interface` appended for link-local IPv6.
        public var address: String
        /// Lower-case, colon-separated, zero-padded.
        public var hardwareAddress: String
    }

    /// Every neighbour the kernel currently caches for `family` (`AF_INET` or
    /// `AF_INET6`). Empty on any failure — this is strictly an optimisation.
    public static func entries(family: Int32) -> [Entry] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_LLINFO]
        var size = 0
        guard sysctl(&mib, 6, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: size)
        guard buffer.withUnsafeMutableBytes({ bytes in
            sysctl(&mib, 6, bytes.baseAddress, &size, nil, 0)
        }) == 0 else { return [] }

        var result: [Entry] = []
        buffer.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= size {
                let header = base.advanced(by: offset).loadUnaligned(as: rt_msghdr.self)
                let length = Int(header.rtm_msglen)
                guard length > MemoryLayout<rt_msghdr>.size, offset + length <= size else { break }
                defer { offset += length }

                // The message carries the destination sockaddr, then the gateway
                // sockaddr (a sockaddr_dl holding the hardware address).
                let destination = base.advanced(by: offset + MemoryLayout<rt_msghdr>.size)
                let destinationLength = socketAddressSize(destination)
                let gateway = destination.advanced(by: destinationLength)
                guard offset + MemoryLayout<rt_msghdr>.size + destinationLength + 2 <= size else { continue }

                guard let address = literal(from: destination, family: family),
                      let hardware = hardwareAddress(from: gateway)
                else { continue }
                result.append(Entry(address: address, hardwareAddress: hardware))
            }
        }
        return result
    }

    /// The IPv4 address of whatever hardware also answers to `host`.
    ///
    /// `host` is normally the IPv6 link-local usbmuxd reported. Returns `nil`
    /// when either cache has nothing to say, which just means we keep using the
    /// address we already had.
    public static func ipv4Peer(of host: String) -> String? {
        let wanted = host.lowercased()
        let bare = wanted.split(separator: "%").first.map(String.init) ?? wanted
        let neighbours = entries(family: AF_INET6)
        guard let match = neighbours.first(where: {
            let candidate = $0.address.lowercased()
            return candidate == wanted || candidate.split(separator: "%").first.map(String.init) == bare
        }) else { return nil }
        return entries(family: AF_INET)
            .first { $0.hardwareAddress == match.hardwareAddress }?
            .address
    }

    // MARK: - sockaddr walking

    /// Routing messages pad every sockaddr up to a 4-byte boundary, and a
    /// zero-length one still occupies 4 bytes.
    private static func socketAddressSize(_ pointer: UnsafeRawPointer) -> Int {
        let length = Int(pointer.load(as: UInt8.self))
        guard length > 0 else { return 4 }
        return (length + 3) & ~3
    }

    private static func literal(from pointer: UnsafeRawPointer, family: Int32) -> String? {
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        guard Int32(bytes[1]) == family else { return nil }

        switch family {
        case AF_INET:
            var address = in_addr()
            memcpy(&address, bytes + 4, MemoryLayout<in_addr>.size)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
            return text(buffer)

        case AF_INET6:
            var raw = [UInt8](repeating: 0, count: 16)
            memcpy(&raw, bytes + 8, 16)
            var scope: UInt32 = 0
            memcpy(&scope, bytes + 24, MemoryLayout<UInt32>.size)
            // KAME hides the interface index in bytes 2-3 of a link-local
            // address rather than in sin6_scope_id; undo that before printing.
            if raw[0] == 0xFE, raw[1] & 0xC0 == 0x80 {
                let embedded = UInt32(raw[2]) << 8 | UInt32(raw[3])
                if embedded != 0 { scope = embedded }
                raw[2] = 0
                raw[3] = 0
            }
            var address = in6_addr()
            memcpy(&address, raw, 16)
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil,
                  var literal = text(buffer)
            else { return nil }
            if scope != 0 {
                var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
                if if_indextoname(scope, &name) != nil, let interface = text(name) {
                    literal += "%" + interface
                }
            }
            return literal

        default:
            return nil
        }
    }

    /// `sockaddr_dl`: len, family, index(2), type, nlen, alen, slen, then the
    /// interface name followed by `alen` bytes of hardware address.
    private static func hardwareAddress(from pointer: UnsafeRawPointer) -> String? {
        let bytes = pointer.assumingMemoryBound(to: UInt8.self)
        guard Int32(bytes[1]) == AF_LINK else { return nil }
        let nameLength = Int(bytes[5])
        let addressLength = Int(bytes[6])
        guard addressLength == 6 else { return nil }
        let start = 8 + nameLength
        return (0..<addressLength)
            .map { String(format: "%02x", bytes[start + $0]) }
            .joined(separator: ":")
    }

    private static func text(_ buffer: [CChar]) -> String? {
        let string = String(
            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return string.isEmpty ? nil : string
    }
}
