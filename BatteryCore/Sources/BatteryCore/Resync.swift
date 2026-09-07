import Foundation

/// What a Resync did and whether it found the phone.
///
/// `discovered` is "something named a device"; `found` is "a reading actually
/// arrived". They come apart in the ordinary blackout case: usbmuxd lists the
/// phone, the phone declines to answer.
public struct ResyncOutcome: Sendable, Equatable {
    /// The addresses that were thrown away, by udid.
    public var forgotten: [String]
    /// Discovery named at least one device.
    public var discovered: Bool
    /// A reading came back.
    public var found: Bool
    public var udid: String?
    public var name: String?
    public var transport: Transport?
    public var reading: BatteryReading?
    /// Why the read failed, when it did.
    public var error: MonitorError?
    public var elapsed: TimeInterval
    /// What was actually done, in the order it happened. The ordering *is* the
    /// contract — see `ResyncSequence`.
    public var steps: [ResyncSequence.Step]

    public init(
        forgotten: [String] = [],
        discovered: Bool = false,
        found: Bool = false,
        udid: String? = nil,
        name: String? = nil,
        transport: Transport? = nil,
        reading: BatteryReading? = nil,
        error: MonitorError? = nil,
        elapsed: TimeInterval = 0,
        steps: [ResyncSequence.Step] = []
    ) {
        self.forgotten = forgotten
        self.discovered = discovered
        self.found = found
        self.udid = udid
        self.name = name
        self.transport = transport
        self.reading = reading
        self.error = error
        self.elapsed = elapsed
        self.steps = steps
    }

    /// One line fit for `os_log`, and for a CLI.
    public var summary: String {
        var parts: [String] = ["resync"]
        parts.append(found ? "found" : (discovered ? "discovered, unreachable" : "no device"))
        if let name { parts.append(name) }
        if let transport { parts.append(transport.rawValue) }
        if let reading { parts.append("\(reading.percent) %") }
        if !forgotten.isEmpty { parts.append("forgot \(forgotten.count) address(es)") }
        if let error { parts.append(error.localizedKey) }
        parts.append(String(format: "%.2f s", elapsed))
        return parts.joined(separator: "  ")
    }
}

/// The order a Resync has to do things in, with every step as a closure.
///
/// Same trick as `PhoneReadRace`: the *decision* lives here and is unit-tested
/// against fakes, while `TandemMonitor.resync()` supplies the real address
/// book, the real session cache and the real transports.
///
/// The order is the whole point. Forgetting the cached address **before**
/// discovery is what makes the next read go through usbmuxd's device list and
/// the neighbour table (`PhoneAddressBook.refreshFromUSBMux`) rather than
/// straight back to the address that has stopped answering; only once discovery
/// has written a fresh address does the direct client get to dial it.
public struct ResyncSequence: Sendable {

    public enum Step: String, Sendable, Equatable, CaseIterable {
        case forgetAddresses
        case dropSessions
        case resetBackoff
        case discover
        case read
    }

    /// Drop every remembered address; returns the udids that were forgotten.
    public typealias Forget = @Sendable () async -> [String]
    /// Close any kept-alive lockdown/diagnostics_relay session.
    public typealias DropSessions = @Sendable () async -> Void
    /// Zero the unreachable ladder and mark the next read urgent.
    public typealias ResetBackoff = @Sendable () async -> Void
    /// usbmuxd's list first, then whatever is left on file.
    public typealias Discover = @Sendable () async -> [PhoneDevice]
    public typealias Read = @Sendable (PhoneDevice) async throws -> BatteryReading

    public init() {}

    public func run(
        startedAt: Date = Date(),
        now: @escaping @Sendable () -> Date = { Date() },
        forgetAddresses: Forget,
        dropSessions: DropSessions,
        resetBackoff: ResetBackoff,
        discover: Discover,
        read: Read
    ) async -> ResyncOutcome {
        var steps: [Step] = []

        let forgotten = await forgetAddresses()
        steps.append(.forgetAddresses)
        await dropSessions()
        steps.append(.dropSessions)
        await resetBackoff()
        steps.append(.resetBackoff)

        let devices = await discover()
        steps.append(.discover)
        guard let device = devices.first else {
            return ResyncOutcome(
                forgotten: forgotten,
                discovered: false,
                found: false,
                error: .noDevice,
                elapsed: now().timeIntervalSince(startedAt),
                steps: steps
            )
        }

        do {
            let reading = try await read(device)
            steps.append(.read)
            return ResyncOutcome(
                forgotten: forgotten,
                discovered: true,
                found: true,
                udid: device.udid,
                name: reading.name.isEmpty ? device.name : reading.name,
                transport: reading.transport,
                reading: reading,
                elapsed: now().timeIntervalSince(startedAt),
                steps: steps
            )
        } catch {
            steps.append(.read)
            return ResyncOutcome(
                forgotten: forgotten,
                discovered: true,
                found: false,
                udid: device.udid,
                name: device.name,
                transport: device.transport,
                error: MonitorError(error),
                elapsed: now().timeIntervalSince(startedAt),
                steps: steps
            )
        }
    }
}
