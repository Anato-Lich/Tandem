import Foundation
import Testing
@testable import BatteryCore

/// The 80 % notification's whole decision, with no notification centre in sight.
@Suite("Charge milestone")
struct ChargeMilestoneTests {

    private static let origin = Date(timeIntervalSince1970: 1_757_000_000)

    /// One phone status, at a given percent and plug state.
    private func status(
        _ percent: Int,
        charging: Bool = true,
        external: Bool = true,
        minutes: Double = 0,
        watts: Double? = 36,
        adapterWatts: Int? = 45,
        kind: DeviceKind = .iphone,
        name: String = "iPhone",
        chargingWatts: Double? = nil,
        isPartial: Bool = false
    ) -> DeviceStatus {
        let timestamp = Self.origin.addingTimeInterval(minutes * 60)
        let reading = BatteryReading(
            deviceID: "udid", kind: kind, name: name, percent: percent,
            isCharging: charging, externalConnected: external, fullyCharged: false,
            rawCurrentMAh: 2000, rawMaxMAh: 4000, designMAh: 4000, voltageMV: 4000,
            instantAmperageMA: charging ? 1500 : -500, batteryPowerW: charging ? 6 : -6,
            systemPowerInW: watts, systemLoadW: nil,
            adapterWatts: adapterWatts, adapterDescription: nil,
            temperatureC: 30, cycleCount: 12,
            timestamp: timestamp, transport: kind == .mac ? .local : .wifi,
            isPartial: isPartial
        )
        return DeviceStatus(reading: reading, chargingWatts: chargingWatts, lastSeen: timestamp)
    }

    @Test("Crossing 80 % while charging fires once, with the session's elapsed time and watts")
    func firesOnTheCrossing() {
        var milestone = ChargeMilestone()

        #expect(milestone.update(status(62, minutes: 0), kind: .iphone) == nil)
        #expect(milestone.update(status(71, minutes: 11), kind: .iphone) == nil)

        let event = milestone.update(status(81, minutes: 23), kind: .iphone)
        #expect(event != nil)
        #expect(event?.kind == .iphone)
        #expect(event?.percent == 81)
        // 23 minutes since the first sample, which is where the session began.
        #expect(event?.elapsed == 23 * 60.0)
        #expect(event?.watts == 36)
        #expect(event?.adapterWatts == 45)

        // Once per session: 82, 83, 84 are not news.
        #expect(milestone.update(status(82, minutes: 26), kind: .iphone) == nil)
        #expect(milestone.update(status(90, minutes: 40), kind: .iphone) == nil)
        #expect(milestone.hasFired)
    }

    @Test("Exactly 80 counts; 79 does not")
    func thresholdIsInclusive() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(78), kind: .iphone)
        #expect(milestone.update(status(79, minutes: 1), kind: .iphone) == nil)
        #expect(milestone.update(status(80, minutes: 2), kind: .iphone) != nil)
    }

    @Test("A phone already past 80 % when we start watching is not news")
    func noEventWithoutACrossing() {
        var milestone = ChargeMilestone()
        // The first sample has no predecessor, so there is nothing to cross.
        #expect(milestone.update(status(91), kind: .iphone) == nil)
        #expect(milestone.update(status(92, minutes: 5), kind: .iphone) == nil)
        #expect(!milestone.hasFired)
    }

    @Test("Plugging in above 80 % does not fire, because the percent never crossed")
    func pluggingInAboveTheThreshold() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(85, charging: false, external: false, watts: nil), kind: .iphone)
        #expect(milestone.update(status(86, minutes: 1), kind: .iphone) == nil)
    }

    @Test("Plugged in but not charging never fires, however the percent moves")
    func heldOnHoldDoesNotFire() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70, charging: false), kind: .iphone)
        #expect(milestone.update(status(84, charging: false, minutes: 30), kind: .iphone) == nil)
    }

    @Test("Unplugging arms the next session; a second charge fires again")
    func unplugResetsTheLatch() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70), kind: .iphone)
        #expect(milestone.update(status(82, minutes: 10), kind: .iphone) != nil)

        // Off the charger: the latch is released and the session start forgotten.
        _ = milestone.update(status(60, charging: false, external: false, minutes: 120, watts: nil), kind: .iphone)
        #expect(!milestone.hasFired)
        #expect(milestone.sessionStart == nil)

        // Back on, and across the line again.
        _ = milestone.update(status(60, minutes: 130), kind: .iphone)
        let second = milestone.update(status(83, minutes: 155), kind: .iphone)
        #expect(second != nil)
        #expect(second?.elapsed == 25 * 60.0)
    }

    @Test("A missed poll is not an unplug")
    func nilStatusChangesNothing() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70), kind: .iphone)
        #expect(milestone.update(nil, kind: .iphone) == nil)
        #expect(milestone.externalConnected)
        // The crossing still lands, and still knows when the session started.
        let event = milestone.update(status(81, minutes: 20), kind: .iphone)
        #expect(event?.elapsed == 20 * 60.0)
    }

    @Test("A session whose start we never saw reports no elapsed time rather than a wrong one")
    func unknownElapsedIsOmitted() {
        var milestone = ChargeMilestone()
        // First sample is already on the charger, so the "start" is this sample.
        _ = milestone.update(status(70, minutes: 0), kind: .iphone)
        let event = milestone.update(status(81, minutes: 0), kind: .iphone)
        #expect(event != nil)
        #expect(event?.elapsed == nil)
    }

    @Test("A start we only assumed is corrected from the history; one we watched is not")
    func seedFillsInAnElapsedTimeFromHistory() {
        // The app launched into a charge already running: the first sample is
        // where we *think* it started, and the history knows better.
        var assumed = ChargeMilestone()
        _ = assumed.update(status(70, minutes: 0), kind: .iphone)
        #expect(!assumed.sessionStartIsObserved)
        assumed.seedSessionStart(Self.origin.addingTimeInterval(-40 * 60))
        #expect(assumed.sessionStart == Self.origin.addingTimeInterval(-40 * 60))
        // A seed can only lengthen a session, never shorten it into a fiction.
        assumed.seedSessionStart(Self.origin.addingTimeInterval(-5 * 60))
        #expect(assumed.sessionStart == Self.origin.addingTimeInterval(-40 * 60))
        let event = assumed.update(status(81, minutes: 23), kind: .iphone)
        #expect(event?.elapsed == 63 * 60.0)

        // A start we actually watched happen is never moved.
        var watched = ChargeMilestone()
        _ = watched.update(status(60, charging: false, external: false, watts: nil), kind: .iphone)
        _ = watched.update(status(61, minutes: 1), kind: .iphone)
        #expect(watched.sessionStartIsObserved)
        watched.seedSessionStart(Self.origin.addingTimeInterval(-40 * 60))
        #expect(watched.sessionStart == Self.origin.addingTimeInterval(60))

        // With nothing plugged in there is nothing to seed either.
        var idle = ChargeMilestone()
        idle.seedSessionStart(Self.origin)
        #expect(idle.sessionStart == nil)
    }

    @Test("Unknown watts stay unknown: a partial reading with no basis reports neither half")
    func partialReadingReportsNoWatts() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70, watts: nil, adapterWatts: nil), kind: .iphone)
        let event = milestone.update(
            status(81, minutes: 10, watts: nil, adapterWatts: nil, isPartial: true),
            kind: .iphone
        )
        #expect(event != nil)
        #expect(event?.watts == nil)
        #expect(event?.adapterWatts == nil)
    }

    @Test("The estimator's watts stand in when the device does not report SystemPowerIn")
    func chargingWattsAreTheFallback() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70, watts: nil, chargingWatts: 18.4), kind: .iphone)
        let event = milestone.update(status(81, minutes: 8, watts: nil, chargingWatts: 18.4), kind: .iphone)
        #expect(event?.watts == 18.4)
    }

    @Test("A zero adapter rating is unknown, not zero")
    func zeroAdapterIsDropped() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70, adapterWatts: 0), kind: .iphone)
        let event = milestone.update(status(81, minutes: 8, adapterWatts: 0), kind: .iphone)
        #expect(event?.adapterWatts == nil)
    }

    @Test("The Mac uses exactly the same rule, and only fires while it is charging")
    func macCrossesTheSameWay() {
        var milestone = ChargeMilestone()
        _ = milestone.update(status(70, kind: .mac, name: "MacBook Pro"), kind: .mac)
        let event = milestone.update(status(80, minutes: 45, kind: .mac, name: "MacBook Pro"), kind: .mac)
        #expect(event?.kind == .mac)
        #expect(event?.deviceName == "MacBook Pro")
        #expect(event?.elapsed == 45 * 60.0)

        // A Mac sitting on a brick, not charging, crossing 80 % by some other
        // route: nothing.
        var plugged = ChargeMilestone()
        _ = plugged.update(status(70, charging: false, kind: .mac), kind: .mac)
        #expect(plugged.update(status(85, charging: false, minutes: 10, kind: .mac), kind: .mac) == nil)
    }
}
