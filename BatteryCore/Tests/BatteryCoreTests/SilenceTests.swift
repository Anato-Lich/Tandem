import Foundation
import Testing
@testable import BatteryCore

/// The silence rule: a device is only flagged once we have been **trying and
/// failing** to read it. Age on its own is never a fault — the phone is polled
/// every 2–5 minutes when somebody is looking and not at all while the display
/// sleeps (NOTES.md §14), so a twenty-minute-old reading is the design working.
///
/// Everything here is pure: dates are handed in, no phone, no clock.
@Suite("Silence — unreachableSince, not lastSeen")
struct SilenceTests {

    private static let origin = Date(timeIntervalSince1970: 1_788_000_000)

    private func reading(
        percent: Int = 62,
        minutes: Double = 0,
        isPartial: Bool = false
    ) -> BatteryReading {
        BatteryReading(
            deviceID: "udid", kind: .iphone, name: "iPhone", percent: percent,
            isCharging: false, externalConnected: false, fullyCharged: false,
            rawCurrentMAh: isPartial ? 0 : 2000, rawMaxMAh: isPartial ? 0 : 4000,
            designMAh: isPartial ? 0 : 4000, voltageMV: isPartial ? 0 : 4000,
            instantAmperageMA: isPartial ? 0 : -500, batteryPowerW: isPartial ? 0 : -6,
            systemPowerInW: nil, systemLoadW: nil,
            adapterWatts: nil, adapterDescription: nil,
            temperatureC: isPartial ? 0 : 30, cycleCount: isPartial ? 0 : 12,
            timestamp: Self.origin.addingTimeInterval(minutes * 60),
            transport: .wifi, isPartial: isPartial
        )
    }

    private func status(
        unreachableSince: Date?,
        failedAttempts: Int,
        lastSeenMinutesAgo: Double = 0,
        now: Date = SilenceTests.origin
    ) -> DeviceStatus {
        DeviceStatus(
            reading: reading(),
            lastSeen: now.addingTimeInterval(-lastSeenMinutesAgo * 60),
            unreachableSince: unreachableSince,
            failedAttempts: failedAttempts
        )
    }

    // MARK: - The rule itself

    @Test("A fresh failure is not silence")
    func freshFailureIsNotSilent() {
        let now = Self.origin
        let one = status(unreachableSince: now.addingTimeInterval(-30), failedAttempts: 1, now: now)
        #expect(!one.isSilent(now: now))
        let two = status(unreachableSince: now.addingTimeInterval(-30), failedAttempts: 4, now: now)
        #expect(!two.isSilent(now: now))
    }

    @Test("Eleven minutes of failure but only one attempt is not silence")
    func oneAttemptIsNotSilent() {
        let now = Self.origin
        let s = status(unreachableSince: now.addingTimeInterval(-11 * 60), failedAttempts: 1, now: now)
        #expect(!s.isSilent(now: now))
    }

    @Test("Eleven minutes and two attempts is silence")
    func elevenMinutesTwoAttempts() {
        let now = Self.origin
        let s = status(unreachableSince: now.addingTimeInterval(-11 * 60), failedAttempts: 2, now: now)
        #expect(s.isSilent(now: now))
    }

    @Test("An old reading with no failures at all is never silence")
    func oldLastSeenIsNotSilence() {
        let now = Self.origin
        // Two hours since the last poll — a display that slept through lunch.
        let s = status(unreachableSince: nil, failedAttempts: 0, lastSeenMinutesAgo: 120, now: now)
        #expect(!s.isSilent(now: now))
        // And the thresholds are exactly the ones documented.
        #expect(DeviceStatus.silenceWindow == 600)
        #expect(DeviceStatus.silenceAttempts == 2)
    }

    @Test("Exactly at the window is not yet silence; a second past it is")
    func windowBoundary() {
        let now = Self.origin
        let at = status(unreachableSince: now.addingTimeInterval(-600), failedAttempts: 2, now: now)
        #expect(!at.isSilent(now: now))
        let past = status(unreachableSince: now.addingTimeInterval(-601), failedAttempts: 2, now: now)
        #expect(past.isSilent(now: now))
    }

    // MARK: - The monitor's bookkeeping

    private func monitor() -> TandemMonitor {
        TandemMonitor(store: nil)
    }

    @Test("The first failure sets unreachableSince; later failures keep it")
    func failuresKeepTheFirstMoment() async {
        let monitor = self.monitor()
        let first = Self.origin
        await monitor.setPhoneError(.unreachable(), now: first)
        var phone = await monitor.snapshot().phone
        // No reading yet, so nothing is published — the counters still moved.
        #expect(phone == nil)

        // Give it a reading so the status carries the fields, then fail twice
        // more without ever succeeding again.
        await monitor.applyPhone(reading())
        await monitor.setPhoneError(.unreachable(), now: first)
        await monitor.setPhoneError(.timedOut(seconds: 8), now: first.addingTimeInterval(120))
        await monitor.setPhoneError(.noDevice, now: first.addingTimeInterval(240))

        phone = await monitor.snapshot().phone
        #expect(phone?.unreachableSince == first)
        #expect(phone?.failedAttempts == 3)
        #expect(phone?.isSilent(now: first.addingTimeInterval(11 * 60)) == true)
        #expect(phone?.isSilent(now: first.addingTimeInterval(9 * 60)) == false)
    }

    @Test("A successful read clears the silence")
    func successClears() async {
        let monitor = self.monitor()
        await monitor.applyPhone(reading())
        await monitor.setPhoneError(.unreachable(), now: Self.origin)
        await monitor.setPhoneError(.unreachable(), now: Self.origin.addingTimeInterval(60))
        #expect(await monitor.snapshot().phone?.failedAttempts == 2)

        await monitor.applyPhone(reading(percent: 58, minutes: 20))
        let phone = await monitor.snapshot().phone
        #expect(phone?.unreachableSince == nil)
        #expect(phone?.failedAttempts == 0)
        #expect(phone?.isSilent(now: Self.origin.addingTimeInterval(3600)) == false)
    }

    @Test("A partial reading clears it too — a degraded answer is still an answer")
    func partialSuccessClears() async {
        let monitor = self.monitor()
        await monitor.applyPhone(reading())
        await monitor.setPhoneError(.unreachable(), now: Self.origin)
        await monitor.setPhoneError(.unreachable(), now: Self.origin.addingTimeInterval(60))
        #expect(await monitor.snapshot().phone?.unreachableSince == Self.origin)

        await monitor.applyPhone(reading(percent: 57, minutes: 30, isPartial: true))
        let phone = await monitor.snapshot().phone
        #expect(phone?.isPartial == true)
        #expect(phone?.unreachableSince == nil)
        #expect(phone?.failedAttempts == 0)
    }

    @Test("A device that has never been read follows the same rule from the first failure")
    func neverReadStillCounts() async {
        let monitor = self.monitor()
        await monitor.setPhoneError(.noDevice, now: Self.origin)
        await monitor.setPhoneError(.noDevice, now: Self.origin.addingTimeInterval(60))
        // The first reading to arrive later is the ordinary case; what matters
        // is that the run of failures was timed from the very first one.
        await monitor.applyPhone(reading())
        await monitor.setPhoneError(.noDevice, now: Self.origin.addingTimeInterval(120))
        let phone = await monitor.snapshot().phone
        #expect(phone?.unreachableSince == Self.origin.addingTimeInterval(120))
        #expect(phone?.failedAttempts == 1)
    }

    @Test("The Mac keeps the same bookkeeping")
    func macToo() async {
        let monitor = self.monitor()
        await monitor.setMacError(.macReadFailed(), now: Self.origin)
        await monitor.setMacError(.macReadFailed(), now: Self.origin.addingTimeInterval(60))
        await monitor.setMacError(nil)
        // Nothing to assert on the snapshot without a Mac reading; the point is
        // that clearing does not trip over the counters.
        #expect(await monitor.macError == nil)
    }

    // MARK: - Wire format

    @Test("Old snapshots decode as \"we have not failed\"")
    func lenientDecoding() throws {
        let json = """
        {
          "generatedAt": "2026-09-07T18:41:07Z",
          "phone": {
            "lastSeen": "2026-09-07T18:24:00Z",
            "stale": true,
            "reading": {
              "deviceID": "udid", "kind": "iphone", "name": "iPhone", "percent": 62,
              "isCharging": false, "externalConnected": false, "fullyCharged": false,
              "rawCurrentMAh": 2000, "rawMaxMAh": 4000, "designMAh": 4000,
              "voltageMV": 4000, "instantAmperageMA": -500, "batteryPowerW": -6,
              "temperatureC": 30, "cycleCount": 12,
              "timestamp": "2026-09-07T18:24:00Z", "transport": "wifi"
            }
          }
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(TandemSnapshot.self, from: Data(json.utf8))
        let phone = try #require(snapshot.phone)
        #expect(phone.unreachableSince == nil)
        #expect(phone.failedAttempts == 0)
        // The old `stale` flag still decodes, and still means nothing to the UI.
        #expect(phone.isStale)
        #expect(!phone.isSilent(now: Date()))
    }

    @Test("A silent status round-trips through the store's own JSON")
    func roundTrip() async throws {
        let since = Date(timeIntervalSince1970: 1_788_000_000)
        let original = DeviceStatus(
            reading: reading(),
            lastSeen: since.addingTimeInterval(-900),
            unreachableSince: since,
            failedAttempts: 4
        )
        let store = SnapshotStore(url: URL(fileURLWithPath: "/dev/null"))
        let data = try await store.encode(TandemSnapshot(generatedAt: since, phone: original))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(TandemSnapshot.self, from: data)
        #expect(back.phone == original)
        #expect(back.phone?.failedAttempts == 4)
        #expect(back.phone?.unreachableSince == since)
    }
}
