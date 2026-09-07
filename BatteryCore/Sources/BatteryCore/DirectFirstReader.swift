import Foundation

/// Which route a read took, and why.
public struct DirectFirstOutcome: Sendable {
    public var reading: BatteryReading
    /// True when the direct-by-IP client produced this reading.
    public var usedDirect: Bool
    /// Why direct was skipped or failed, when it was.
    public var directError: String?
    /// The address the fallback path discovered, if it refreshed one.
    public var refreshedHost: String?

    public init(
        reading: BatteryReading,
        usedDirect: Bool,
        directError: String? = nil,
        refreshedHost: String? = nil
    ) {
        self.reading = reading
        self.usedDirect = usedDirect
        self.directError = directError
        self.refreshedHost = refreshedHost
    }
}

/// The direct-first / usbmuxd-fallback decision, factored out of
/// `PhoneBatterySource` so it can be tested without a phone.
///
/// The rule, in one sentence: if we know an address, try the direct client
/// there; otherwise, or if that fails, fall back to usbmuxd, and if *that*
/// works ask it where the phone is so the next attempt has an address.
public struct DirectFirstReader: Sendable {

    /// Read via `DirectLockdownClient` at the given address (which may carry
    /// more than one candidate host).
    public typealias DirectRead = @Sendable (PhoneAddress) async throws -> BatteryReading
    /// Read via the libimobiledevice/usbmuxd path.
    public typealias FallbackRead = @Sendable () async throws -> BatteryReading
    /// Ask usbmuxd where the phone is; called only after a successful fallback.
    public typealias AddressLookup = @Sendable () async -> String?

    /// Try the direct path at all. `false` reproduces the old behaviour exactly.
    public var useDirect: Bool
    /// Never fall back. A failed direct attempt is then the whole answer, which
    /// is what `tandemctl once --direct-only` wants.
    public var directOnly: Bool
    /// Ignore a cached address older than this. `nil` means never expire — the
    /// default, because a stale address costs one fast connect refusal and a
    /// phone's DHCP lease usually outlives any window we care about.
    public var maximumAddressAge: TimeInterval?

    public init(useDirect: Bool = true, directOnly: Bool = false, maximumAddressAge: TimeInterval? = nil) {
        self.useDirect = useDirect
        self.directOnly = directOnly
        self.maximumAddressAge = maximumAddressAge
    }

    /// Is this cached address worth dialling?
    public func shouldTryDirect(_ address: PhoneAddress?, now: Date = Date()) -> Bool {
        guard useDirect, let address else { return false }
        guard let limit = maximumAddressAge else { return true }
        return address.age(at: now) <= limit
    }

    public func read(
        cachedAddress: PhoneAddress?,
        now: Date = Date(),
        direct: DirectRead,
        fallback: FallbackRead,
        lookupAddress: AddressLookup
    ) async throws -> DirectFirstOutcome {

        var directError: String?

        if useDirect {
            if shouldTryDirect(cachedAddress, now: now), let address = cachedAddress {
                do {
                    return DirectFirstOutcome(reading: try await direct(address), usedDirect: true)
                } catch {
                    // --direct-only wants the real reason, not a fallback result.
                    if directOnly { throw error }
                    directError = String(describing: error)
                }
            } else if directOnly {
                throw DirectLockdownError.noAddress(udid: cachedAddress?.udid ?? "")
            } else {
                directError = cachedAddress == nil
                    ? "no cached address"
                    : "cached address is older than \(maximumAddressAge.map { "\(Int($0)) s" } ?? "the limit")"
            }
        } else if directOnly {
            throw DirectLockdownError.noAddress(udid: cachedAddress?.udid ?? "")
        }

        let reading = try await fallback()
        let refreshed = await lookupAddress()
        return DirectFirstOutcome(
            reading: reading,
            usedDirect: false,
            directError: directError,
            refreshedHost: refreshed
        )
    }
}
