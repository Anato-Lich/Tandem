import Foundation
import Testing
@testable import BatteryCore

/// Schema v4 — the nullable `readings.system_load_w` column and the sparkline
/// series the summary window draws from it.
@Suite("System load: the v4 column and the sparkline series")
struct SystemLoadSeriesTests {

    private func row(
        at timestamp: Date,
        percent: Int,
        systemLoad: Double?
    ) throws -> HistoryReading {
        var row = try HistoryFixtures.phoneRow(at: timestamp, percent: percent)
        row.systemLoadW = systemLoad
        return row
    }

    // MARK: - Migration

    @Test("A v3 file gains the column in place, keeps its rows, and reads them back as unknown")
    func migratesFromV3() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/history.sqlite")

        // Hand-build exactly what v3 was: no `system_load_w` anywhere.
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try database.execute("""
                CREATE TABLE readings (
                    ts REAL NOT NULL, device TEXT NOT NULL, percent INTEGER NOT NULL,
                    is_charging INTEGER NOT NULL, external INTEGER NOT NULL,
                    fully_charged INTEGER NOT NULL, watts REAL, adapter_watts INTEGER,
                    raw_current_mah INTEGER, raw_max_mah INTEGER, design_mah INTEGER,
                    cycle_count INTEGER, temperature_c REAL,
                    is_partial INTEGER NOT NULL DEFAULT 0,
                    transport TEXT NOT NULL DEFAULT 'local');
                CREATE INDEX idx_readings_device_ts ON readings (device, ts);
                CREATE TABLE devices (id TEXT PRIMARY KEY, kind TEXT NOT NULL,
                    name TEXT NOT NULL, last_seen REAL NOT NULL);
                CREATE TABLE sessions (device TEXT NOT NULL, start REAL NOT NULL, end REAL,
                    from_percent INTEGER NOT NULL, to_percent INTEGER NOT NULL,
                    peak_watts REAL, average_watts REAL, adapter_watts INTEGER,
                    reached_80_at REAL, energy_wh REAL, PRIMARY KEY (device, start));
                CREATE TABLE markers (ts REAL NOT NULL, kind TEXT NOT NULL, PRIMARY KEY (ts, kind));
                """)
            try database.execute("""
                INSERT INTO readings (ts, device, percent, is_charging, external, fully_charged, is_partial, transport)
                VALUES (\(referenceDate.timeIntervalSince1970), 'legacy', 55, 0, 0, 0, 0, 'local')
                """)
            try database.execute("INSERT INTO meta (key, value) VALUES ('version','3')")
        }

        let store = HistoryStore(url: url)
        // Straight through v4 to whatever the build is on now — the walk in
        // `migrate` runs every step it is behind, in one transaction.
        #expect(try await store.storedSchemaVersion() >= 4)
        #expect(try await store.storedSchemaVersion() == HistoryStore.schemaVersion)

        // The pre-v4 row survived, and its new column reads back as *unknown*
        // rather than as a machine that drew nothing (NOTES.md §15.1).
        let legacy = try #require(try await store.readings(device: "legacy").first)
        #expect(legacy.percent == 55)
        #expect(legacy.systemLoadW == nil)
        #expect(try await store.systemLoadSeries(device: "legacy").isEmpty)

        // The column is writable straight after the migration.
        _ = try await store.record(
            try row(at: referenceDate.addingTimeInterval(60), percent: 40, systemLoad: 12.5)
        )
        let fresh = try #require(try await store.readings(device: HistoryFixtures.phoneID).last)
        #expect(fresh.systemLoadW == 12.5)

        // Idempotent: reopening neither re-runs `ALTER TABLE` nor loses a row.
        let again = HistoryStore(url: url)
        #expect(try await again.storedSchemaVersion() == HistoryStore.schemaVersion)
        #expect(try await again.readingCount() == 2)
    }

    @Test("A fresh file writes and reads the column, and a row with no telemetry stays nil")
    func roundTripsOnAFreshFile() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        _ = try await store.record(try row(at: referenceDate, percent: 40, systemLoad: 9.5))
        _ = try await store.record(
            try row(at: referenceDate.addingTimeInterval(600), percent: 41, systemLoad: nil)
        )

        let rows = try await store.readings(device: HistoryFixtures.phoneID)
        #expect(rows.map(\.systemLoadW) == [9.5, nil])
    }

    @Test("A reading's system load is carried onto the row it becomes")
    func projectsFromAStatus() async throws {
        var reading = try HistoryFixtures.phoneReading()
        reading.systemLoadW = 2.4
        #expect(HistoryReading(status: HistoryFixtures.status(reading)).systemLoadW == 2.4)

        reading.systemLoadW = nil
        #expect(HistoryReading(status: HistoryFixtures.status(reading)).systemLoadW == nil)
    }

    // MARK: - The series

    @Test("The series is the last twelve figures, oldest first, with the blanks skipped")
    func seriesIsTheLastTwelveKnownFigures() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        // Twenty rows, ten minutes apart so nothing is skipped, every third one
        // with no telemetry at all.
        for step in 0..<20 {
            let load = step % 3 == 0 ? nil : Double(step)
            _ = try await store.record(
                try row(
                    at: referenceDate.addingTimeInterval(Double(step) * 600),
                    percent: 40 + step,
                    systemLoad: load
                )
            )
        }

        let series = try await store.systemLoadSeries(device: HistoryFixtures.phoneID)
        #expect(series.count == HistoryStore.systemLoadSeriesLimit)
        // Oldest first, and never a null read back as zero: 20 rows minus the
        // seven blanks leaves 13 figures, of which the newest twelve are kept.
        #expect(series == [2, 4, 5, 7, 8, 10, 11, 13, 14, 16, 17, 19].map(Double.init))

        // A device that has never reported telemetry gets nothing rather than
        // a flat line at zero.
        #expect(try await store.systemLoadSeries(device: "nobody").isEmpty)
        #expect(try await store.systemLoadSeries(device: HistoryFixtures.phoneID, limit: 3) == [16, 17, 19])
    }

    @Test("The summary carries the series, and it survives the JSON round trip")
    func summaryCarriesTheSeries() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        try await store.noteDevice(
            id: HistoryFixtures.phoneID, kind: .iphone, name: "iPhone", lastSeen: referenceDate
        )
        for step in 0..<5 {
            _ = try await store.record(
                try row(
                    at: referenceDate.addingTimeInterval(Double(step) * 600),
                    percent: 40 + step,
                    systemLoad: 1.5 + Double(step)
                )
            )
        }

        let entry = try #require(
            try await store.summary(for: HistoryFixtures.phoneID, now: referenceDate.addingTimeInterval(3600))
        )
        #expect(entry.systemLoadSeries == [1.5, 2.5, 3.5, 4.5, 5.5])

        let data = try HistoryStore.encoder.encode(entry)
        let decoded = try HistoryStore.decoder.decode(DeviceHistory.self, from: data)
        #expect(decoded.systemLoadSeries == entry.systemLoadSeries)
    }

    @Test("A summary written before the column existed still decodes")
    func decodesSummaryJSONWithoutTheKey() throws {
        // Exactly the shape §15.4 documents, minus `systemLoadSeries`.
        let json = """
        {
          "device": "mac-0001",
          "kind": "mac",
          "name": "MacBook Pro",
          "percent": 90,
          "isCharging": false,
          "series": [],
          "week": []
        }
        """
        let decoded = try HistoryStore.decoder.decode(DeviceHistory.self, from: Data(json.utf8))
        #expect(decoded.device == "mac-0001")
        #expect(decoded.percent == 90)
        #expect(decoded.systemLoadSeries.isEmpty)
    }

    @Test("System load drifting does not by itself write a row")
    func systemLoadIsNotPartOfTheSkipRule() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))

        #expect(try await store.record(try row(at: referenceDate, percent: 62, systemLoad: 10)) == true)
        // Five minutes later, nothing but the system load has moved. Recording
        // it would cost a row a minute forever on an otherwise idle machine.
        #expect(
            try await store.record(
                try row(at: referenceDate.addingTimeInterval(300), percent: 62, systemLoad: 31)
            ) == false
        )
    }
}
