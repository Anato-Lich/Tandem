import Foundation
import Testing
@testable import BatteryCore

@Suite("PollingPolicy")
struct PollingPolicyTests {

    @Test("Steady-state cadences")
    func steadyState() {
        let policy = PollingPolicy()
        #expect(policy.nextDelay(state: .charging) == 60)
        #expect(policy.nextDelay(state: .discharging) == 120)
    }

    @Test("Unreachable backs off 60 -> 120 -> 300 -> 600 and stays capped")
    func backoff() {
        let policy = PollingPolicy()
        let observed = (1...7).map { policy.nextDelay(state: .unreachable, consecutiveFailures: $0) }
        #expect(observed == [60, 120, 300, 600, 600, 600, 600])
        // A zeroth failure is treated as the first step rather than crashing.
        #expect(policy.nextDelay(state: .unreachable, consecutiveFailures: 0) == 60)
    }

    @Test("Any external event polls immediately", arguments: PollingPolicy.State.allCases)
    func externalEventResets(state: PollingPolicy.State) {
        let policy = PollingPolicy()
        #expect(policy.nextDelay(state: state, consecutiveFailures: 9, externalEvent: true) == 0)
    }

    @Test("A successful poll leaves the backoff behind")
    func recovery() {
        let policy = PollingPolicy()
        #expect(policy.nextDelay(state: .unreachable, consecutiveFailures: 4) == 600)
        // The caller resets the counter on success; the delay follows the state.
        #expect(policy.nextDelay(state: .charging, consecutiveFailures: 0) == 60)
    }

    @Test("State is derived from the reading")
    func stateFromReading() throws {
        let charging = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingUSB.data)
        let discharging = try BatteryPlistParser.parseMac(Fixture.macDischarging.data)
        #expect(PollingPolicy.state(for: charging) == .charging)
        #expect(PollingPolicy.state(for: discharging) == .discharging)
    }

    @Test("Intervals are configurable")
    func customIntervals() {
        let policy = PollingPolicy(chargingInterval: 5, dischargingInterval: 10, unreachableBackoff: [1, 2])
        #expect(policy.nextDelay(state: .charging) == 5)
        #expect(policy.nextDelay(state: .discharging) == 10)
        #expect(policy.nextDelay(state: .unreachable, consecutiveFailures: 3) == 2)
    }
}
