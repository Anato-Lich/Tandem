import Foundation

/// Races the phone's two transports against each other, then drops to the
/// degraded tier if both full reads fail.
///
/// Why: a failed *direct* attempt costs a whole connect timeout (8 s by
/// default) while a failed *usbmuxd* attempt costs about a millisecond, so
/// running them one after the other made `tandemctl once` take ~14 s in a
/// blackout for an answer that was never coming. Running them together costs
/// the slower of the two, not the sum, and the first success wins.
///
/// The tiers, in order (NOTES.md §13):
///
/// 1. **full** — `AppleSmartBattery` over IORegistry, by whichever transport
///    answers first. Everything the app renders comes from here.
/// 2. **partial** — lockdown `GetValue` on `com.apple.mobile.battery`, tried
///    only when a full read failed in a way that says *the phone answered and
///    the relay did not*. Four fields; `BatteryReading.isPartial` is set.
///
/// This type owns only the ordering and the budget. The legs — their transports,
/// their own timeouts — are closures supplied by `PhoneBatterySource`, which is
/// what makes the whole decision testable with no phone in the room.
public struct PhoneReadRace: Sendable {

    /// Which leg produced (or failed to produce) a reading.
    public enum Route: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
        case direct
        case usbmux
        case directPartial
        case usbmuxPartial

        public var isPartial: Bool { self == .directPartial || self == .usbmuxPartial }
        public var usesDirect: Bool { self == .direct || self == .directPartial }
    }

    /// One transport attempt, already configured with its own timeouts.
    public struct Leg: Sendable {
        public var route: Route
        public var read: @Sendable () async throws -> BatteryReading

        public init(_ route: Route, read: @escaping @Sendable () async throws -> BatteryReading) {
            self.route = route
            self.read = read
        }
    }

    public struct Outcome: Sendable {
        public var reading: BatteryReading
        public var route: Route
        /// Every leg that failed, by route, as text fit for a log line.
        public var errors: [Route: String]
        public var elapsed: TimeInterval

        public var isPartial: Bool { route.isPartial }
        public var usedDirect: Bool { route.usesDirect }

        public init(
            reading: BatteryReading,
            route: Route,
            errors: [Route: String] = [:],
            elapsed: TimeInterval = 0
        ) {
            self.reading = reading
            self.route = route
            self.errors = errors
            self.elapsed = elapsed
        }
    }

    /// Hard cap on the whole tiered read, both tiers included. 8 s is the number
    /// the brief asks for: it is one direct connect timeout, and the point is
    /// that a blackout can no longer cost more than one.
    public var budget: TimeInterval
    /// Run the partial tier even when the full failures looked like an
    /// unreachable phone. Off by default: dialling a phone whose radio is off
    /// twice is just twice the wait.
    public var alwaysTryPartial: Bool

    public init(budget: TimeInterval = 8, alwaysTryPartial: Bool = false) {
        self.budget = budget
        self.alwaysTryPartial = alwaysTryPartial
    }

    /// Does this failure mean "the phone is up, the relay is not"?
    ///
    /// That is the one state the partial tier can rescue: lockdown handshake,
    /// session TLS and `StartService` all succeeded and only the relay read
    /// EOF'd (NOTES.md §12.8, §12.9). A connect timeout means the radio is off,
    /// and `GetValue` will not fare better.
    public static func suggestsPartialTier(_ error: any Error) -> Bool {
        switch MonitorError(error) {
        case .relayRefused, .malformedResponse, .timedOut:
            return true
        default:
            return false
        }
    }

    /// Race `full`, then fall back to `partial`.
    ///
    /// - Parameters:
    ///   - full: legs producing a complete `BatteryReading`. Run concurrently;
    ///     the first success wins and the others are cancelled.
    ///   - partial: legs producing a `isPartial` reading, run only if every full
    ///     leg failed and at least one failed "reachably".
    ///   - startedAt: injectable clock origin, for tests.
    /// - Throws: the first full-tier error in leg order (so `--direct-only`
    ///   still reports the real reason), or `MonitorError.noDevice` if no leg
    ///   was offered at all.
    public func read(
        full: [Leg],
        partial: [Leg] = [],
        startedAt: Date = Date()
    ) async throws -> Outcome {
        guard !full.isEmpty || !partial.isEmpty else { throw MonitorError.noDevice }
        let cap = startedAt.addingTimeInterval(budget)

        var errors: [Route: String] = [:]
        var ordered: [any Error] = []

        if !full.isEmpty {
            let result = await Self.race(full, deadline: cap)
            switch result {
            case .success(let reading, let route):
                return Outcome(
                    reading: reading,
                    route: route,
                    errors: errors,
                    elapsed: Date().timeIntervalSince(startedAt)
                )
            case .failure(let failures):
                for (route, error) in failures {
                    errors[route] = String(describing: error)
                    ordered.append(error)
                }
            }
        }

        let reachable = alwaysTryPartial || ordered.contains(where: Self.suggestsPartialTier)
        if !partial.isEmpty, reachable, cap.timeIntervalSinceNow > 0.25 {
            let result = await Self.race(partial, deadline: cap)
            switch result {
            case .success(let reading, let route):
                return Outcome(
                    reading: reading,
                    route: route,
                    errors: errors,
                    elapsed: Date().timeIntervalSince(startedAt)
                )
            case .failure(let failures):
                for (route, error) in failures {
                    errors[route] = String(describing: error)
                    ordered.append(error)
                }
            }
        }

        throw ordered.first ?? MonitorError.noDevice
    }

    // MARK: - The race itself

    /// `any Error` is not `Sendable`, and a task group element must be. The
    /// values here never leave the actor-free scope of one `read`, so the
    /// unchecked conformance is honest.
    private struct LegResult: @unchecked Sendable {
        var route: Route
        var reading: BatteryReading?
        var error: (any Error)?
    }

    private enum RaceResult {
        case success(BatteryReading, Route)
        /// In leg-declaration order, so the first one is the one worth throwing.
        case failure([(Route, any Error)])
    }

    private static func race(_ legs: [Leg], deadline: Date) async -> RaceResult {
        var collected: [Route: any Error] = [:]
        var expired = false

        let winner: (BatteryReading, Route)? = await withTaskGroup(
            of: LegResult?.self,
            returning: (BatteryReading, Route)?.self
        ) { group in
            for leg in legs {
                group.addTask {
                    do {
                        return LegResult(route: leg.route, reading: try await leg.read(), error: nil)
                    } catch {
                        return LegResult(route: leg.route, reading: nil, error: error)
                    }
                }
            }
            // The budget leg. It reports `nil`, which ends the race whatever the
            // others are still doing; `cancelAll` then unwinds them.
            group.addTask {
                let remaining = deadline.timeIntervalSinceNow
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
                return nil
            }

            defer { group.cancelAll() }
            var pending = legs.count
            while let result = await group.next() {
                guard let result else { expired = true; break }
                if let reading = result.reading { return (reading, result.route) }
                if let error = result.error { collected[result.route] = error }
                pending -= 1
                if pending == 0 { break }
            }
            return nil
        }

        if let winner { return .success(winner.0, winner.1) }

        // Report failures in leg-declaration order: the first leg is the one we
        // believed in, so its error is the one worth throwing.
        var ordered: [(Route, any Error)] = []
        for leg in legs {
            if let error = collected[leg.route] {
                ordered.append((leg.route, error))
            } else if expired {
                ordered.append((leg.route, MonitorError.timedOut(seconds: max(0, deadline.timeIntervalSince(Date()) * -1))))
            }
        }
        if ordered.isEmpty { ordered = [(legs[0].route, MonitorError.noDevice)] }
        return .failure(ordered)
    }
}
