import Foundation
import Testing
@testable import BatteryCore

@Suite("History store: schema, the skip rule, retention")
struct HistoryStoreTests {

    private func makeStore(
        in directory: URL,
        retention: TimeInterval = 30 * 86_400,
        idleInterval: TimeInterval = 600,
        pruneInterval: TimeInterval = 86_400
    ) -> HistoryStore {
        HistoryStore(
            url: directory.appendingPathComponent("nested/history.sqlite"),
            retention: retention,
            idleInterval: idleInterval,
            pruneInterval: pruneInterval
        )
    }

    @Test("A fresh file lands on the current schema version, in WAL mode, and survives a reopen")
    func walOpenAndReopen() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore(in: directory)
        try await store.prepare()
        #expect(try await store.journalMode().lowercased() == "wal")
        #expect(try await store.storedSchemaVersion() == HistoryStore.schemaVersion)

        for minute in 0..<4 {
            _ = try await store.record(
                try HistoryFixtures.phoneRow(at: referenceDate.addingTimeInterval(Double(minute) * 300), percent: 40 + minute)
            )
        }
        #expect(FileManager.default.fileExists(atPath: store.url.path))
        #expect(FileManager.default.fileExists(atPath: store.url.path + "-wal"))

        // A second connection on the same file sees everything the first wrote.
        let reopened = makeStore(in: directory)
        let rows = try await reopened.readings(device: HistoryFixtures.phoneID)
        #expect(rows.count == 4)
        #expect(rows.map(\.percent) == [40, 41, 42, 43])
        #expect(try await reopened.storedSchemaVersion() == HistoryStore.schemaVersion)
    }

    @Test("A v1 file is migrated in place and keeps its rows")
    func migratesFromV1() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/history.sqlite")

        // Hand-build exactly what v1 was: meta plus readings, nothing else.
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
                """)
            try database.execute("""
                INSERT INTO readings (ts, device, percent, is_charging, external, fully_charged, is_partial, transport)
                VALUES (\(referenceDate.timeIntervalSince1970), 'legacy', 55, 0, 0, 0, 0, 'local')
                """)
            try database.execute("INSERT INTO meta (key, value) VALUES ('version','1')")
        }

        let store = HistoryStore(url: url)
        #expect(try await store.storedSchemaVersion() == HistoryStore.schemaVersion)
        #expect(try await store.readingCount(device: "legacy") == 1)
        // The v2 tables now exist and are usable.
        #expect(try await store.sessions(device: "legacy").isEmpty)
        #expect(try await store.devices().isEmpty)
        // …and so does v3's, which a v1 file has never had a column of.
        #expect(try await store.markers().isEmpty)
        // Idempotent: opening again does not re-run the migration or lose rows.
        let again = HistoryStore(url: url)
        #expect(try await again.storedSchemaVersion() == HistoryStore.schemaVersion)
        #expect(try await again.readingCount() == 1)
    }

    @Test("An unchanged reading is skipped until the idle interval has passed")
    func skipsUnchangedReadings() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)

        let base = try HistoryFixtures.phoneRow(at: referenceDate, percent: 62, watts: 15.0)
        #expect(try await store.record(base) == true)

        // Same everything, five minutes later: nothing material changed.
        var same = base
        same.timestamp = referenceDate.addingTimeInterval(300)
        #expect(try await store.record(same) == false)

        // Watts drifting inside the half-watt tolerance is still "unchanged".
        var drifted = base
        drifted.timestamp = referenceDate.addingTimeInterval(540)
        drifted.watts = 15.4
        #expect(try await store.record(drifted) == false)

        // Past the tolerance it is a real change and goes in immediately.
        var jumped = base
        jumped.timestamp = referenceDate.addingTimeInterval(560)
        jumped.watts = 15.6
        #expect(try await store.record(jumped) == true)

        // Unchanged again, but now ten minutes have passed: keep the heartbeat.
        var idle = jumped
        idle.timestamp = referenceDate.addingTimeInterval(560 + 600)
        #expect(try await store.record(idle) == true)

        #expect(try await store.readingCount(device: HistoryFixtures.phoneID) == 3)
    }

    @Test("Each material field on its own forces a row")
    func materialChangesForceARow() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let base = try HistoryFixtures.phoneRow(at: referenceDate, percent: 62, charging: true, external: true)
        let mutations: [(String, (inout HistoryReading) -> Void)] = [
            ("percent", { $0.percent = 63 }),
            ("charging", { $0.isCharging = false }),
            ("external", { $0.externalConnected = false }),
            ("fullyCharged", { $0.fullyCharged = true }),
            ("watts became unknown", { $0.watts = nil }),
        ]
        for (label, mutate) in mutations {
            let directory = HistoryFixtures.temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let store = makeStore(in: directory)
            #expect(try await store.record(base) == true, "\(label): base row")
            var changed = base
            changed.timestamp = referenceDate.addingTimeInterval(60)
            mutate(&changed)
            #expect(try await store.record(changed) == true, "\(label) should force a row")
        }
    }

    @Test("A row older than the newest one is refused")
    func refusesOutOfOrderRows() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)

        #expect(try await store.record(try HistoryFixtures.phoneRow(at: referenceDate, percent: 50)) == true)
        #expect(try await store.record(try HistoryFixtures.phoneRow(at: referenceDate.addingTimeInterval(-60), percent: 20)) == false)
        #expect(try await store.record(try HistoryFixtures.phoneRow(at: referenceDate, percent: 99)) == false)
        #expect(try await store.readingCount() == 1)
    }

    @Test("Recording a snapshot writes one row per device and remembers both")
    func recordsSnapshots() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)

        let first = try HistoryFixtures.snapshot(at: referenceDate, macPercent: 81, phonePercent: 62)
        #expect(try await store.record(first, now: referenceDate) == 2)

        // A minute later with nothing changed: both devices skip.
        let repeated = try HistoryFixtures.snapshot(at: referenceDate.addingTimeInterval(60), macPercent: 81, phonePercent: 62)
        #expect(try await store.record(repeated, now: referenceDate.addingTimeInterval(60)) == 0)

        // The phone gains a percent; the Mac has not moved.
        let moved = try HistoryFixtures.snapshot(at: referenceDate.addingTimeInterval(120), macPercent: 81, phonePercent: 63)
        #expect(try await store.record(moved, now: referenceDate.addingTimeInterval(120)) == 1)

        let devices = try await store.devices()
        #expect(devices.count == 2)
        #expect(devices.map(\.kind) == [.mac, .iphone])
        #expect(try await store.resolveDevice("iphone")?.id == HistoryFixtures.phoneID)
        #expect(try await store.resolveDevice("mac")?.id == HistoryFixtures.macID)
        #expect(try await store.resolveDevice(HistoryFixtures.macID)?.kind == .mac)
        #expect(try await store.resolveDevice("nonsense") == nil)
    }

    @Test("Rows and finished sessions older than the retention window are pruned")
    func prunesOldRows() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory, retention: 30 * 86_400)
        let now = referenceDate

        // Two rows well outside the window, then one inside it.
        for offset in [-40.0, -35.0] {
            _ = try await store.record(
                try HistoryFixtures.phoneRow(at: now.addingTimeInterval(offset * 86_400), percent: 50, external: true)
            )
        }
        _ = try await store.record(try HistoryFixtures.phoneRow(at: now.addingTimeInterval(-86_400), percent: 70, external: true))
        #expect(try await store.readingCount() == 3)
        #expect(try await store.sessions(device: HistoryFixtures.phoneID).isEmpty == false)

        let deleted = try await store.prune(now: now)
        #expect(deleted == 2)
        #expect(try await store.readingCount() == 1)
        let remaining = try await store.sessions(device: HistoryFixtures.phoneID)
        #expect(remaining.allSatisfy { $0.start >= now.addingTimeInterval(-30 * 86_400) })
    }

    @Test("record prunes, but not more than once a day")
    func prunesAtMostDaily() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory, retention: 30 * 86_400, pruneInterval: 86_400)
        let now = referenceDate

        // The first snapshot arms the once-a-day clock.
        _ = try await store.record(try HistoryFixtures.snapshot(at: now, macPercent: 80, phonePercent: 60), now: now)

        // A stale row for a third device, inserted directly so the ordering rule
        // does not reject it.
        let stale = try HistoryFixtures.phoneRow(at: now.addingTimeInterval(-40 * 86_400), percent: 10, device: "stale-device")
        #expect(try await store.record(stale) == true)

        // An hour later: prune is not due, so the stale row is still there.
        _ = try await store.record(
            try HistoryFixtures.snapshot(at: now.addingTimeInterval(3600), macPercent: 81, phonePercent: 61),
            now: now.addingTimeInterval(3600)
        )
        #expect(try await store.readingCount(device: "stale-device") == 1)

        // Two days later it is due, and the stale row goes.
        _ = try await store.record(
            try HistoryFixtures.snapshot(at: now.addingTimeInterval(2 * 86_400), macPercent: 82, phonePercent: 62),
            now: now.addingTimeInterval(2 * 86_400)
        )
        #expect(try await store.readingCount(device: "stale-device") == 0)
    }

    @Test("Sessions are materialised as rows arrive and match a full rebuild")
    func materialisesSessions() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore(in: directory)

        let script: [(minutes: Double, percent: Int, external: Bool)] = [
            (0, 40, false), (10, 38, false),
            (20, 38, true), (50, 62, true), (80, 88, true),
            (90, 88, false), (120, 80, false),
            (150, 80, true), (180, 96, true),
        ]
        for step in script {
            _ = try await store.record(
                try HistoryFixtures.phoneRow(
                    at: referenceDate.addingTimeInterval(step.minutes * 60),
                    percent: step.percent,
                    charging: step.external,
                    external: step.external
                )
            )
        }

        let incremental = try await store.sessions(device: HistoryFixtures.phoneID)
        #expect(incremental.count == 2)
        // Newest first.
        #expect(incremental[0].start == referenceDate.addingTimeInterval(150 * 60))
        #expect(incremental[0].isOpen)
        #expect(incremental[1].end == referenceDate.addingTimeInterval(80 * 60))
        #expect(incremental[1].fromPercent == 38)
        #expect(incremental[1].toPercent == 88)
        #expect(incremental[1].reached80At == referenceDate.addingTimeInterval(80 * 60))

        // The incremental rebuild done on every insert agrees with a full one.
        let rebuilt = try await store.rebuildSessions(device: HistoryFixtures.phoneID)
        #expect(rebuilt == incremental)
    }
}
