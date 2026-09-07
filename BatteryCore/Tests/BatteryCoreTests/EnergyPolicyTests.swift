import Foundation
import Testing
@testable import BatteryCore

/// The energy policy of NOTES.md §14: who is looking decides how often the
/// phone is dialled. Everything here is pure — no sleeping, no phone, no
/// widget, no clock beyond the dates the tests hand in.
@Suite("Energy policy")
struct EnergyPolicyTests {

    // MARK: - Cadence per level and state

    @Test("Hidden never polls the phone, in any state")
    func hiddenNeverPollsPhone() {
        let policy = PollingPolicy()
        for state in PollingPolicy.State.allCases {
            #expect(policy.phoneDelay(level: .hidden, state: state) == nil)
            // Not even an event brings it back: the caller re-checks the level.
            #expect(policy.phoneDelay(level: .hidden, state: state, externalEvent: true) == nil)
        }
        #expect(ActivityLevel.hidden.pollsPhone == false)
        #expect(ActivityLevel.allCases.filter(\.pollsPhone).count == 3)
    }

    @Test("The phone cadence table")
    func phoneCadence() {
        let policy = PollingPolicy()
        #expect(policy.phoneDelay(level: .background, state: .charging) == 120)
        #expect(policy.phoneDelay(level: .background, state: .discharging) == 300)
        #expect(policy.phoneDelay(level: .widgetVisible, state: .charging) == 60)
        #expect(policy.phoneDelay(level: .widgetVisible, state: .discharging) == 120)
        #expect(policy.phoneDelay(level: .popoverOpen, state: .charging) == 15)
        #expect(policy.phoneDelay(level: .popoverOpen, state: .discharging) == 15)
    }

    @Test("The Mac is only slowed, never stopped")
    func macCadence() {
        let policy = PollingPolicy()
        #expect(policy.macDelay(level: .hidden, state: .charging) == 600)
        #expect(policy.macDelay(level: .hidden, state: .discharging) == 600)
        #expect(policy.macDelay(level: .background, state: .charging) == 60)
        #expect(policy.macDelay(level: .widgetVisible, state: .discharging) == 120)
        // Even hidden, a plug event is read at once.
        #expect(policy.macDelay(level: .hidden, state: .discharging, externalEvent: true) == 0)
    }

    // MARK: - Backoff

    @Test("Unreachable backoff caps at 600 s, not 300")
    func backoffCap() {
        let policy = PollingPolicy()
        #expect((1...6).map(policy.backoff) == [60, 120, 300, 600, 600, 600])
        #expect(policy.backoff(0) == 60)
        #expect(policy.unreachableBackoff.last == 600)
    }

    @Test("Backoff is reconciled with the level, not layered on top of it")
    func backoffPerLevel() {
        let policy = PollingPolicy()
        // Background: never retried faster than the 300 s cadence it would
        // have had anyway, and still reaching the 600 s cap.
        let background = (1...5).map { policy.phoneDelay(level: .background, state: .unreachable, consecutiveFailures: $0) }
        #expect(background == [300, 300, 300, 600, 600])
        // Widget visible: the ladder shows through above its own 120 s floor.
        let widget = (1...5).map { policy.phoneDelay(level: .widgetVisible, state: .unreachable, consecutiveFailures: $0) }
        #expect(widget == [120, 120, 300, 600, 600])
        // Popover: somebody is watching, so 15 s wins over the whole ladder.
        let popover = (1...5).map { policy.phoneDelay(level: .popoverOpen, state: .unreachable, consecutiveFailures: $0) }
        #expect(popover == [15, 15, 15, 15, 15])
    }

    @Test("Any event polls now, at every level that polls at all",
          arguments: [ActivityLevel.background, .widgetVisible, .popoverOpen])
    func eventResets(level: ActivityLevel) {
        let policy = PollingPolicy()
        for state in PollingPolicy.State.allCases {
            #expect(policy.phoneDelay(level: level, state: state, consecutiveFailures: 9, externalEvent: true) == 0)
        }
    }

    @Test("An event brings a read forward but cannot outpace the level")
    func eventFloor() {
        let policy = PollingPolicy()
        // The fastest cadence each level would ever use on its own — so a
        // phone that flaps in and out of usbmuxd every 15 s (NOTES.md §5)
        // cannot poll its way back to the old 1400 requests a day.
        #expect(policy.eventFloor(level: .background) == 120)
        #expect(policy.eventFloor(level: .widgetVisible) == 60)
        #expect(policy.eventFloor(level: .popoverOpen) == 15)
        #expect(policy.eventFloor(level: .hidden) == nil)
        // Never slower than the level's own steady cadence, at any level.
        for level in ActivityLevel.allCases.filter(\.pollsPhone) {
            let floor = try! #require(policy.eventFloor(level: level))
            let fastest = try! #require(policy.phoneInterval(level: level, state: .charging))
            #expect(floor <= max(fastest, policy.popoverInterval))
        }
    }

    // MARK: - Widget marker freshness

    @Test("A marker is fresh for ten minutes")
    func markerFreshness() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let marker = WidgetActivityMarker(requestedAt: now.addingTimeInterval(-9 * 60), family: "medium")
        #expect(marker.isFresh(now: now))
        #expect(marker.age(now: now) == 9 * 60)

        let old = WidgetActivityMarker(requestedAt: now.addingTimeInterval(-11 * 60), family: "small")
        #expect(old.isFresh(now: now) == false)

        // Exactly at the window is already too old; a marker from the future
        // (clock change) counts as fresh rather than as an error.
        let edge = WidgetActivityMarker(requestedAt: now.addingTimeInterval(-600), family: "small")
        #expect(edge.isFresh(now: now) == false)
        let future = WidgetActivityMarker(requestedAt: now.addingTimeInterval(30), family: "small")
        #expect(future.isFresh(now: now))
        #expect(future.age(now: now) == 0)
    }

    @Test("A fresh marker raises the level to widgetVisible; hidden still wins")
    func markerFloor() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = WidgetActivityMarker(requestedAt: now.addingTimeInterval(-60), family: "medium")
        let stale = WidgetActivityMarker(requestedAt: now.addingTimeInterval(-3600), family: "medium")

        #expect(ActivityLevel.floor(marker: fresh, now: now) == .widgetVisible)
        #expect(ActivityLevel.floor(marker: stale, now: now) == .background)
        #expect(ActivityLevel.floor(marker: nil, now: now) == .background)

        #expect(ActivityLevel.background.raised(to: .widgetVisible) == .widgetVisible)
        #expect(ActivityLevel.popoverOpen.raised(to: .widgetVisible) == .popoverOpen)
        // A sleeping display is not showing a widget, whatever the file says.
        #expect(ActivityLevel.hidden.raised(to: .widgetVisible) == .hidden)
    }

    @Test("The marker round-trips through its own JSON")
    func markerCoding() throws {
        let marker = WidgetActivityMarker(requestedAt: Date(timeIntervalSince1970: 1_700_000_000), family: "small")
        let data = try WidgetActivityMarker.encode(marker)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"family\":\"small\""))
        #expect(text.contains("2023-11-14T"))
        #expect(try WidgetActivityMarker.decode(data) == marker)
    }

    @Test("Levels order by visibility")
    func ordering() {
        #expect(ActivityLevel.hidden < .background)
        #expect(ActivityLevel.background < .widgetVisible)
        #expect(ActivityLevel.widgetVisible < .popoverOpen)
        #expect(max(ActivityLevel.background, .widgetVisible) == .widgetVisible)
    }

    // MARK: - etaTo80At

    @Test("etaTo80At is the absolute deadline of etaTo80 at read time")
    func absoluteDeadline() throws {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingUSB.data)
        let status = DeviceStatus(reading: reading, etaTo80: 15 * 60, lastSeen: taken)

        #expect(status.etaTo80At == taken.addingTimeInterval(900))
        // Five minutes later the countdown has run down by five minutes, with
        // no new poll involved.
        #expect(status.timeTo80(now: taken.addingTimeInterval(300)) == 600)
        // Past the deadline it is zero, never negative, and `reached80` says so.
        #expect(status.timeTo80(now: taken.addingTimeInterval(1200)) == 0)
        #expect(status.reached80(now: taken.addingTimeInterval(1200)))
        #expect(status.reached80(now: taken) == false)

        // No ETA at all stays nil rather than becoming "now".
        let noEta = DeviceStatus(reading: reading, lastSeen: taken)
        #expect(noEta.etaTo80At == nil)
        #expect(noEta.timeTo80(now: taken) == nil)
        #expect(noEta.reached80(now: taken) == false)
    }

    @Test("A snapshot written before etaTo80At still counts down")
    func legacyDecode() async throws {
        let taken = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingUSB.data)
        let status = DeviceStatus(reading: reading, etaTo80: 600, lastSeen: taken)
        let store = SnapshotStore(url: URL(fileURLWithPath: "/dev/null"))
        let encoded = try await store.encode(TandemSnapshot(generatedAt: taken, phone: status))

        // Strip the new key, exactly as an older writer would have left it.
        var object = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var phone = try #require(object["phone"] as? [String: Any])
        phone.removeValue(forKey: "etaTo80At")
        object["phone"] = phone
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(TandemSnapshot.self, from: stripped)
        #expect(restored.phone?.etaTo80At == taken.addingTimeInterval(600))
        #expect(restored.phone?.timeTo80(now: taken.addingTimeInterval(120)) == 480)
    }

    @Test("Stats count phone requests by level")
    func statsSummary() {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = PollStats(
            since: since,
            level: .widgetVisible,
            phoneAttempts: 13,
            phoneSuccesses: 12,
            phoneAttemptsByLevel: ["background": 5, "widgetVisible": 7, "popoverOpen": 1],
            phoneSuccessesByLevel: ["background": 5, "widgetVisible": 6, "popoverOpen": 1],
            macReads: 42
        )
        let now = since.addingTimeInterval(3600)
        #expect(stats.attempts(at: .widgetVisible) == 7)
        #expect(stats.attempts(at: .hidden) == 0)
        #expect(stats.successes(at: .widgetVisible) == 6)
        #expect(stats.projectedPerDay(now: now) == 13 * 24)
        let summary = stats.summary(now: now)
        #expect(summary.contains("phone 12/13 ok"))
        #expect(summary.contains("level widgetVisible"))
        #expect(summary.contains("widgetVisible 7"))
        // Too early to extrapolate: no invented rate in the first minute.
        #expect(stats.projectedPerDay(now: since.addingTimeInterval(10)) == 0)
    }
}
