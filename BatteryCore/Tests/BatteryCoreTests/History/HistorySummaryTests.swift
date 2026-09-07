import Foundation
import Testing
@testable import BatteryCore

@Suite("History summary and its JSON")
struct HistorySummaryTests {

    /// Whole seconds throughout: the summary is encoded with ISO-8601 dates,
    /// which have no sub-second component, so a round-trip is only equal if the
    /// dates going in were whole seconds too.
    private let now = referenceDate

    private func populated(_ directory: URL) async throws -> HistoryStore {
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        // Twelve hours of phone: four on the charger from 30 % to 92 %, then off
        // it, sampled every ten minutes.
        try await store.noteDevice(id: HistoryFixtures.phoneID, kind: .iphone, name: "iPhone", lastSeen: now)
        for step in 0..<72 {
            let minutes = Double(step) * 10
            let timestamp = now.addingTimeInterval(minutes * 60 - 12 * 3600)
            let charging = minutes >= 120 && minutes < 360
            let percent = charging
                ? min(92, 30 + Int((minutes - 120) / 4))
                : max(20, 92 - Int(max(0, minutes - 360) / 12))
            _ = try await store.record(
                try HistoryFixtures.phoneRow(
                    at: timestamp,
                    percent: charging ? percent : (minutes < 120 ? 30 : percent),
                    charging: charging,
                    external: charging,
                    watts: charging ? 14.0 : -1.6,
                    adapterWatts: charging ? 45 : nil
                )
            )
        }
        return store
    }

    @Test("The summary carries health, cycles, the last session, today and a 24 h series")
    func summaryShape() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await populated(directory)

        let entry = try #require(try await store.summary(for: HistoryFixtures.phoneID, now: now))
        #expect(entry.kind == .iphone)
        #expect(entry.name == "iPhone")

        // Health comes from the newest full reading; the fixture's gauge is
        // healthy but not brand new.
        let health = try #require(entry.health)
        #expect(health.rawMaxMAh > 0)
        #expect(health.designMAh > 0)
        #expect(health.percent <= 100)
        #expect(abs(health.fraction - Double(health.rawMaxMAh) / Double(health.designMAh)) < 0.0001)
        #expect(entry.cycleCount != nil)
        #expect(entry.temperatureC != nil)

        let session = try #require(entry.lastSession)
        #expect(session.isOpen == false)
        #expect(session.fromPercent == 30)
        #expect(session.toPercent == 87)
        #expect(session.adapterWatts == 45)
        #expect(session.peakWatts == 14.0)
        #expect(session.reached80At != nil)
        #expect((session.energyWh ?? 0) > 0)

        #expect(entry.today != nil)
        #expect(entry.week.isEmpty == false)
        #expect(entry.series.isEmpty == false)
        #expect(entry.series.count <= HistoryStore.seriesPointLimit)
        #expect(entry.series.allSatisfy { $0.t >= now.addingTimeInterval(-24 * 3600) })
        #expect(entry.series.contains { $0.isCharging })
    }

    @Test("Health is capped at 100 % even when the gauge reports more than design")
    func healthIsCapped() {
        let overfull = BatteryHealth(rawMaxMAh: 5200, designMAh: 4966)
        #expect(overfull.percent == 100)
        #expect(overfull.fraction > 1.0)
        let worn = BatteryHealth(rawMaxMAh: 4200, designMAh: 4966)
        #expect(worn.percent == 85)
    }

    @Test("The summary round-trips through its JSON unchanged")
    func jsonRoundTrip() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await populated(directory)

        let summary = try await store.summary(now: now)
        #expect(summary.devices.count == 1)

        let data = try await store.encodeSummary(summary)
        let text = try #require(String(data: data, encoding: .utf8))
        // Pretty-printed and key-sorted, like the snapshot file next to it.
        #expect(text.contains("\n"))
        #expect(text.contains("\"cycleCount\""))
        #expect(text.contains("\"lastSession\""))
        #expect(text.contains("\"series\""))

        let decoded = try HistoryStore.decoder.decode(HistorySummary.self, from: data)
        #expect(decoded == summary)
        #expect(decoded.device(kind: .iphone)?.device == HistoryFixtures.phoneID)
        #expect(decoded.device(HistoryFixtures.phoneID) != nil)
    }

    @Test("writeSummary drops a readable file where the widget can find it")
    func writesSummaryFile() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await populated(directory)

        let target = directory.appendingPathComponent("container/summary.json")
        let written = try await store.writeSummary(to: target, now: now)
        #expect(FileManager.default.fileExists(atPath: target.path))

        let reloaded = try HistoryStore.decoder.decode(HistorySummary.self, from: try Data(contentsOf: target))
        #expect(reloaded == written)

        // Rewriting replaces the file in place rather than piling up siblings.
        _ = try await store.writeSummary(to: target, now: now)
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: directory.appendingPathComponent("container").path
        )
        #expect(siblings == ["summary.json"])
    }

    @Test("An empty store summarises to nothing rather than to zeroes")
    func emptyStore() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        let summary = try await store.summary(now: now)
        #expect(summary.devices.isEmpty)
        #expect(try await store.summary(for: "nobody", now: now) == nil)
    }

    @Test("A device known only from partial readings reports unknown health, not zero")
    func partialOnlyDevice() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        // Exactly what the degraded tier gives us (NOTES.md section 13.2).
        let reading = BatteryReading.partial(
            deviceID: "phone-partial",
            name: "iPhone",
            percent: 73,
            isCharging: false,
            externalConnected: false,
            timestamp: now
        )
        let status = DeviceStatus(reading: reading, lastSeen: now)
        let row = HistoryReading(status: status)
        #expect(row.isPartial)
        #expect(row.watts == nil)
        #expect(row.rawMaxMAh == nil)
        #expect(row.cycleCount == nil)
        #expect(row.temperatureC == nil)

        try await store.noteDevice(id: "phone-partial", kind: .iphone, name: "iPhone", lastSeen: now)
        _ = try await store.record(row)

        let entry = try #require(try await store.summary(for: "phone-partial", now: now))
        #expect(entry.percent == 73)
        #expect(entry.health == nil)
        #expect(entry.cycleCount == nil)
        #expect(entry.temperatureC == nil)
        #expect(entry.lastSession == nil)
    }
}
