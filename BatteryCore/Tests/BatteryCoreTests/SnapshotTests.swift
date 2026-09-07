import Foundation
import Testing
@testable import BatteryCore

@Suite("Snapshot, store and formatting")
struct SnapshotTests {

    private func statuses() throws -> (mac: DeviceStatus, phone: DeviceStatus) {
        var estimator = ChargeEstimator()
        let macReading = try BatteryPlistParser.parseMac(
            Fixture.macDischarging.data, deviceID: "mac", name: "MacBook Pro", timestamp: referenceDate
        )
        let phoneReading = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneChargingWiFi.data, deviceID: "phone", name: "iPhone",
            transport: .wifi, timestamp: referenceDate
        )
        return (
            DeviceStatus(reading: macReading, estimate: estimator.ingest(macReading), lastSeen: referenceDate),
            DeviceStatus(reading: phoneReading, estimate: estimator.ingest(phoneReading), lastSeen: referenceDate)
        )
    }

    @Test("Snapshots round-trip through the store atomically")
    func storeRoundTrip() async throws {
        let (mac, phone) = try statuses()
        let snapshot = TandemSnapshot(generatedAt: referenceDate, mac: mac, phone: phone)

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandem-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SnapshotStore(url: directory.appendingPathComponent("nested/snapshot.json"))

        try await store.write(snapshot)
        #expect(FileManager.default.fileExists(atPath: store.url.path))
        let reloaded = try await store.read()
        #expect(reloaded == snapshot)

        // Overwriting in place keeps a single file.
        try await store.write(snapshot)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("nested").path) == ["snapshot.json"])
    }

    @Test("The stale flag serialises as \"stale\"")
    func staleCodingKey() async throws {
        let (mac, _) = try statuses()
        var stale = mac
        stale.isStale = true
        let store = SnapshotStore(url: URL(fileURLWithPath: "/dev/null"))
        let json = try await store.encode(TandemSnapshot(generatedAt: referenceDate, mac: stale))
        let text = String(decoding: json, as: UTF8.self)
        #expect(text.contains("\"stale\" : true"))
        #expect(!text.contains("isStale"))
    }

    @Test("Status lines read the way the brief specifies")
    func formatting() throws {
        let (mac, phone) = try statuses()
        let macLine = StatusFormatter.line(for: mac, now: referenceDate)
        // MacBook Pro  81 %  discharging  -32.6 W  2:46 left
        #expect(macLine.hasPrefix("MacBook Pro  81 %  discharging  "))
        #expect(macLine.contains("\u{2212}32.6 W"))
        #expect(macLine.hasSuffix("2:46 left"))

        let phoneLine = StatusFormatter.line(for: phone, now: referenceDate)
        // Plugged in: what the adapter supplies over what it is rated for, then
        // what the phone itself is drawing (SystemLoad 1900 mW).
        #expect(phoneLine == "iPhone  28 %  charging  13.0/15 W  system 1.9 W  80 % in 53 min  wifi")
    }

    @Test("A stale status says so")
    func staleFormatting() throws {
        let (mac, _) = try statuses()
        var stale = mac
        stale.isStale = true
        let line = StatusFormatter.line(for: stale, now: referenceDate.addingTimeInterval(600))
        #expect(line.contains("(stale, 10 min old)"))
    }

    @Test("Duration helpers")
    func durations() {
        #expect(StatusFormatter.shortDuration(52.87 * 60, units: .english) == "53 min")
        #expect(StatusFormatter.shortDuration(0, units: .english) == "0 min")
        #expect(StatusFormatter.shortDuration(3600, units: .english) == "1 h 00 min")
        #expect(StatusFormatter.shortDuration(9960, units: .english) == "2 h 46 min")
        #expect(StatusFormatter.clockDuration(9960) == "2:46")
        #expect(StatusFormatter.clockDuration(26_760) == "7:26")
    }

    @Test("Russian durations keep the English shape, unit words apart")
    func russianDurations() {
        // The four forms the UI actually shows: the menu's countdown, the
        // widget's `80 % · 14 min`, the summary's `80 % in 2 h 08 min` tail and
        // the "on charger" row's long total.
        #expect(StatusFormatter.shortDuration(14 * 60, units: .russian) == "14 мин")
        #expect(StatusFormatter.shortDuration(52.87 * 60, units: .russian) == "53 мин")
        #expect(StatusFormatter.shortDuration(0, units: .russian) == "0 мин")
        #expect(StatusFormatter.shortDuration(3600, units: .russian) == "1 ч 00 мин")
        #expect(StatusFormatter.shortDuration(7680, units: .russian) == "2 ч 08 мин")
        #expect(StatusFormatter.shortDuration(41_760, units: .russian) == "11 ч 36 мин")
        // Same widths as English: number, space, unit — and the hour form keeps
        // its zero padding, which `DateComponentsFormatter` would have dropped.
        #expect(StatusFormatter.shortDuration(7680, units: .english) == "2 h 08 min")
        #expect(StatusFormatter.shortDuration(41_760, units: .english) == "11 h 36 min")
        // Numbers stay numbers in both languages.
        #expect(StatusFormatter.clockDuration(15_540) == "4:19")
        #expect(StatusFormatter.shortDuration(-60, units: .russian) == "--")
    }

    @Test("Units follow the language, and unknown languages fall back to English")
    func durationUnitsByLanguage() {
        #expect(DurationUnits.forLanguage("ru") == .russian)
        #expect(DurationUnits.forLanguage("ru-RU") == .russian)
        #expect(DurationUnits.forLanguage("en") == .english)
        #expect(DurationUnits.forLanguage("de") == .english)
        #expect(DurationUnits.forLanguage("") == .english)
        // `tandemctl` and the test runner are bare executables with no
        // localizations, so the resolved default is English there.
        #expect(DurationUnits.current == .english)
    }

    @Test("Full and plugged-but-not-charging read differently")
    func stateWords() throws {
        var reading = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingUSB.data)
        #expect(StatusFormatter.stateWord(reading) == "charging")
        reading.isCharging = false
        #expect(StatusFormatter.stateWord(reading) == "plugged")
        reading.fullyCharged = true
        #expect(StatusFormatter.stateWord(reading) == "full")
    }
}

@Suite("AsyncSignal")
struct AsyncSignalTests {

    @Test("A signal cuts a long sleep short")
    func wakesEarly() async {
        let signal = AsyncSignal()
        let started = Date()
        async let sleeping: Bool = signal.sleep(seconds: 30)
        try? await Task.sleep(for: .milliseconds(30))
        signal.signal()
        // `sleep` now reports *why* it returned, which is what resets the
        // monitor's unreachable backoff on an event (NOTES.md §14).
        #expect(await sleeping)
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A signal with no waiter is remembered")
    func remembersPendingSignal() async {
        let signal = AsyncSignal()
        signal.signal()
        let started = Date()
        #expect(await signal.sleep(seconds: 30))
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test("A zero delay returns immediately")
    func zeroDelay() async {
        let signal = AsyncSignal()
        let started = Date()
        await signal.sleep(seconds: 0)
        #expect(Date().timeIntervalSince(started) < 1)
    }
}

@Suite("PhoneRetryPolicy")
struct PhoneRetryPolicyTests {

    @Test("Defaults match the observed Wi-Fi flapping")
    func defaults() {
        #expect(PhoneRetryPolicy.default.attempts == 3)
        #expect(PhoneRetryPolicy.default.gap == 3)
        #expect(PhoneRetryPolicy.default.deadline == 8)
        #expect(PhoneRetryPolicy.none.attempts == 1)
        #expect(PhoneRetryPolicy(attempts: 0, gap: -5).attempts == 1)
        #expect(PhoneRetryPolicy(attempts: 0, gap: -5).gap == 0)
    }

    @Test("Only a pairing failure is permanent")
    func transience() {
        #expect(PhoneError.noDevice(udid: nil).isTransient)
        #expect(PhoneError.unreachable(code: -8).isTransient)
        #expect(PhoneError.serviceFailed(code: -27).isTransient)
        #expect(PhoneError.queryFailed(code: -4).isTransient)
        #expect(PhoneError.timedOut(after: 8).isTransient)
        #expect(!PhoneError.notPaired(code: -21).isTransient)
    }
}
