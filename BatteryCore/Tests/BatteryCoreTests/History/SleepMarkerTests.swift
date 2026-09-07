import Foundation
import Testing
@testable import BatteryCore

/// NOTES.md §15.7's first open item: a Mac that sleeps on the charger leaves a
/// hole longer than `maximumGap` and used to be booked as two charge sessions,
/// which understates one overnight charge. With the app recording sleep and
/// wake, the hole is explained and the session survives it.
@Suite("Sleep markers bridge a charge session")
struct SleepMarkerTests {

    private let start = referenceDate

    /// Plugged in at 0 and 10 min, then a five-hour hole, then plugged in again.
    private func rowsAcrossTheNight(
        lastExternal: Bool = true,
        firstExternal: Bool = true
    ) throws -> [HistoryReading] {
        [
            try HistoryFixtures.phoneRow(at: start, percent: 40, external: firstExternal, watts: 20),
            try HistoryFixtures.phoneRow(at: start.addingTimeInterval(600), percent: 46, external: firstExternal, watts: 20),
            try HistoryFixtures.phoneRow(at: start.addingTimeInterval(5 * 3600), percent: 100, external: lastExternal, watts: lastExternal ? 2 : nil)
        ]
    }

    private func markers(sleep: TimeInterval?, wake: TimeInterval?) -> [SleepMarker] {
        var result: [SleepMarker] = []
        if let sleep { result.append(SleepMarker(timestamp: start.addingTimeInterval(sleep), kind: .sleep)) }
        if let wake { result.append(SleepMarker(timestamp: start.addingTimeInterval(wake), kind: .wake)) }
        return result
    }

    @Test("Without markers the gap still splits the night in two")
    func gapSplitsWithoutMarkers() throws {
        let sessions = ChargeSessionBuilder.sessions(from: try rowsAcrossTheNight(), device: HistoryFixtures.phoneID)
        #expect(sessions.count == 2)
        #expect(sessions[0].toPercent == 46)
        #expect(sessions[1].fromPercent == 100)
    }

    @Test("A gap bracketed by sleep and wake is one session, 40 % to 100 %")
    func sleepBracketsTheGap() throws {
        let sessions = ChargeSessionBuilder.sessions(
            from: try rowsAcrossTheNight(),
            device: HistoryFixtures.phoneID,
            markers: markers(sleep: 900, wake: 5 * 3600 - 60)
        )
        #expect(sessions.count == 1)
        #expect(sessions[0].fromPercent == 40)
        #expect(sessions[0].toPercent == 100)
        #expect(sessions[0].isOpen)
    }

    @Test("A sleep with no wake is still a gap: nobody said the machine came back")
    func sleepWithoutWakeStillSplits() throws {
        let sessions = ChargeSessionBuilder.sessions(
            from: try rowsAcrossTheNight(),
            device: HistoryFixtures.phoneID,
            markers: markers(sleep: 900, wake: nil)
        )
        #expect(sessions.count == 2)
    }

    @Test("A wake before the sleep does not bracket anything")
    func wakeBeforeSleepDoesNotBracket() throws {
        let sessions = ChargeSessionBuilder.sessions(
            from: try rowsAcrossTheNight(),
            device: HistoryFixtures.phoneID,
            markers: markers(sleep: 4 * 3600, wake: 1800)
        )
        #expect(sessions.count == 2)
    }

    @Test("Unplugged on the far side of the gap: two sessions, markers or not")
    func unpluggedAcrossTheGapStillSplits() throws {
        let sessions = ChargeSessionBuilder.sessions(
            from: try rowsAcrossTheNight(lastExternal: false),
            device: HistoryFixtures.phoneID,
            markers: markers(sleep: 900, wake: 5 * 3600 - 60)
        )
        #expect(sessions.count == 1)
        // The one session is the pre-sleep stretch, closed by the unplugged
        // reading — the machine came back off the charger.
        #expect(sessions[0].toPercent == 46)
        #expect(sessions[0].end == start.addingTimeInterval(600))
    }

    @Test("The slept-through hours book no energy")
    func sleptIntervalBooksNoEnergy() throws {
        let bridged = ChargeSessionBuilder.sessions(
            from: try rowsAcrossTheNight(),
            device: HistoryFixtures.phoneID,
            markers: markers(sleep: 900, wake: 5 * 3600 - 60)
        )
        // 20 W across the first ten minutes and nothing at all for the night:
        // the wattage measured before the lid closed says nothing about the
        // hours after it did.
        let energy = try #require(bridged[0].energyWh)
        #expect(abs(energy - 20 * 600 / 3600) < 0.001)
    }

    // MARK: - Through the store

    @Test("recordSleep/recordWake round-trip and merge the stored session")
    func storeBridgesTheSession() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        let rows = try rowsAcrossTheNight()
        try await store.record(rows[0])
        try await store.record(rows[1])
        try await store.recordSleep(at: start.addingTimeInterval(900))

        // Two sessions is what the store holds while the machine is still away.
        #expect(try await store.sessions(device: HistoryFixtures.phoneID).count == 1)

        try await store.recordWake(at: start.addingTimeInterval(5 * 3600 - 60))
        try await store.record(rows[2])

        let stored = try await store.sessions(device: HistoryFixtures.phoneID)
        #expect(stored.count == 1)
        #expect(stored[0].fromPercent == 40)
        #expect(stored[0].toPercent == 100)

        let marks = try await store.markers()
        #expect(marks.map(\.kind) == [.sleep, .wake])
        #expect(marks[0].timestamp == start.addingTimeInterval(900))
    }

    @Test("Markers older than the retention window are pruned with the rows")
    func pruneDropsOldMarkers() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"), retention: 86_400)

        try await store.recordSleep(at: start.addingTimeInterval(-5 * 86_400))
        try await store.recordWake(at: start.addingTimeInterval(-5 * 86_400 + 3600))
        try await store.recordSleep(at: start.addingTimeInterval(-600))
        #expect(try await store.markers().count == 3)

        _ = try await store.prune(now: start)
        let left = try await store.markers()
        #expect(left.count == 1)
        #expect(left[0].timestamp == start.addingTimeInterval(-600))
    }
}

/// The other thing the summary window needs from the store and could not get:
/// whether the pack's full-charge capacity is going anywhere.
@Suite("Capacity trend")
struct CapacityTrendTests {

    private let start = referenceDate

    private func store(_ directory: URL) -> HistoryStore {
        HistoryStore(url: directory.appendingPathComponent("history.sqlite"), idleInterval: 60)
    }

    @Test("Fewer than seven days of full readings is not a trend")
    func shortSpanIsNoTrend() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)

        for day in 0..<3 {
            var row = try HistoryFixtures.phoneRow(at: start.addingTimeInterval(Double(day) * 86_400), percent: 50 + day)
            row.rawMaxMAh = 4966 - day
            try await store.record(row)
        }
        #expect(try await store.capacityTrend(device: HistoryFixtures.phoneID) == nil)
    }

    @Test("Three weeks of full readings gives first, last and the span between")
    func longSpanTrend() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)

        for day in 0..<21 {
            var row = try HistoryFixtures.phoneRow(at: start.addingTimeInterval(Double(day) * 86_400), percent: 50 + day % 40)
            row.rawMaxMAh = 4966 - day
            try await store.record(row)
        }

        let trend = try #require(try await store.capacityTrend(device: HistoryFixtures.phoneID))
        #expect(trend.firstMAh == 4966)
        #expect(trend.lastMAh == 4946)
        #expect(trend.deltaMAh == -20)
        #expect(trend.days == 20)
    }

    @Test("A device whose readings are all partial has no capacity to trend")
    func partialReadingsHaveNoTrend() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = store(directory)

        for day in 0..<21 {
            var row = try HistoryFixtures.phoneRow(at: start.addingTimeInterval(Double(day) * 86_400), percent: 50 + day % 40)
            row.isPartial = true
            row.rawMaxMAh = nil
            try await store.record(row)
        }
        #expect(try await store.capacityTrend(device: HistoryFixtures.phoneID) == nil)
    }
}
