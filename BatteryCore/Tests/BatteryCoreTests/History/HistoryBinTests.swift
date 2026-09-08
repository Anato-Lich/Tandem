import Foundation
import Testing
@testable import BatteryCore

/// The 24 h chart's bins (`ChargeSessionBuilder.bins`), the v5 column behind
/// them (`readings.power_in_w`) and the JSON they travel in.
@Suite("The 24 h bins, the v5 column and their JSON")
struct HistoryBinTests {

    /// UTC throughout, so "the half hour `now` is in" is the same half hour on
    /// every machine that runs the suite.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// A half-hour grid `now` sits 27 minutes into, so the last bin is a
    /// genuinely partial one.
    private let now = Date(timeIntervalSince1970: 1_788_768_000 + 27 * 60)
    private var firstBinStart: Date { now.addingTimeInterval(-27 * 60 - 47 * 1800) }

    private func row(
        minutesBeforeNow: Double,
        percent: Int,
        charging: Bool = false,
        external: Bool = false,
        powerIn: Double? = nil,
        load: Double? = nil
    ) -> HistoryReading {
        HistoryReading(
            timestamp: now.addingTimeInterval(-minutesBeforeNow * 60),
            device: "mac",
            percent: percent,
            isCharging: charging,
            externalConnected: external,
            fullyCharged: false,
            systemLoadW: load,
            powerInW: powerIn
        )
    }

    private func bins(_ rows: [HistoryReading], markers: [SleepMarker] = []) -> [HistoryBin] {
        ChargeSessionBuilder.bins(from: rows, device: "mac", now: now, calendar: calendar, markers: markers)
    }

    private func marker(minutesBeforeNow: Double, _ kind: SleepMarker.Kind) -> SleepMarker {
        SleepMarker(timestamp: now.addingTimeInterval(-minutesBeforeNow * 60), kind: kind)
    }

    /// Minutes before `now` that land `offset` minutes *before* the window's
    /// first bin, so a seeding reading can be placed at a known distance from
    /// it: the window is 47 whole bins plus the 27 minutes `now` is into the
    /// last one.
    private func beforeWindow(_ offset: Double) -> Double { 27 + 47 * 30 + offset }

    // MARK: - The grid

    @Test("48 half-hour bins, aligned to the clock, the last one ending at now")
    func grid() {
        let result = bins([row(minutesBeforeNow: 0, percent: 50)])
        #expect(result.count == 48)
        #expect(result.first?.start == firstBinStart)
        #expect(result.last?.start == now.addingTimeInterval(-27 * 60))
        // Every bin starts on a whole or a half hour.
        for bin in result {
            let minute = calendar.component(.minute, from: bin.start)
            #expect(minute == 0 || minute == 30)
            #expect(calendar.component(.second, from: bin.start) == 0)
        }
        for (index, bin) in result.enumerated() {
            #expect(bin.start == firstBinStart.addingTimeInterval(Double(index) * 1800))
        }
    }

    // MARK: - Percent

    @Test("A bin takes the last reading in it; a short gap carries the figure forward")
    func carriedPercent() {
        // Readings in the two oldest bins and in the newest one; the 45 bins in
        // between are a hole nobody watched.
        let result = bins([
            row(minutesBeforeNow: 1425, percent: 80),   // bin 0
            row(minutesBeforeNow: 1410, percent: 78),   // bin 0, later
            row(minutesBeforeNow: 1395, percent: 70),   // bin 1
            row(minutesBeforeNow: 5, percent: 41)       // bin 47
        ])
        #expect(result[0].percent == 78)                // the last one in the bin
        #expect(result[1].percent == 70)
        #expect(result[0].isObserved)
        #expect(result[1].isObserved)
        // Bin 2 ends 45 minutes after the last reading, bin 3 ends 75 minutes
        // after it: the first still carries, the second is past the hour.
        #expect(result[2].percent == 70)
        #expect(result[2].state == .battery)
        #expect(result[2].isObserved == false)
        #expect(result[3...46].allSatisfy { $0.percent == nil })
        #expect(result[3...46].allSatisfy { $0.state == .unknown })
        #expect(result[3...46].allSatisfy { $0.isObserved == false })
        #expect(result[47].percent == 41)
        // And nothing is invented for the gap: no power, no load.
        #expect(result[20].powerInW == nil)
        #expect(result[20].systemLoadW == nil)
    }

    @Test("A gap of an hour or less keeps the level; the bin past the hour does not")
    func carryWindow() {
        // One reading, 63 minutes back, in bin 45. Bin 46 ends 33 minutes after
        // it and inherits both the level and the state; the last bin ends at
        // `now`, 63 minutes after the only thing anyone measured, and does not.
        let result = bins([row(minutesBeforeNow: 63, percent: 55, external: true)])
        #expect(result[45].percent == 55)
        #expect(result[45].isObserved)
        #expect(result[46].percent == 55)
        #expect(result[46].state == .mains)
        #expect(result[46].isObserved == false)
        #expect(result[47].percent == nil)
        #expect(result[47].state == .unknown)
        #expect(result[47].powerInW == nil)
    }

    @Test("The last bin goes unknown once the newest reading is over an hour old")
    func staleLastBin() {
        // 58 minutes: still inside the window, so the present is still the
        // level we last saw.
        let fresh = bins([row(minutesBeforeNow: 58, percent: 76)])
        #expect(fresh[47].percent == 76)
        #expect(fresh[47].state == .battery)
        #expect(fresh[47].isObserved == false)

        // 61: the app has nothing to say about right now.
        let stale = bins([row(minutesBeforeNow: 61, percent: 76)])
        #expect(stale[47].percent == nil)
        #expect(stale[47].state == .unknown)
    }

    @Test("A phone that goes off the air is unknown, not a flat shelf")
    func phoneGapWithNoMarkers() {
        // The screenshot this rule came from: 76 % at 01:00, silence while the
        // Mac's display slept, and 52 % when the polling came back ten hours
        // later. No markers apply to a phone, so nothing bridges the hole.
        let rows = (0..<6).map { row(minutesBeforeNow: 1400 - Double($0) * 10, percent: 76) }
            + [row(minutesBeforeNow: 60, percent: 52)]
        let result = bins(rows, markers: [marker(minutesBeforeNow: 1300, .sleep), marker(minutesBeforeNow: 100, .wake)])
        // Two bins of carry after the last morning reading, then nothing.
        #expect(result[3].percent == 76)
        #expect(result[5...44].allSatisfy { $0.percent == nil })
        #expect(result[5...44].allSatisfy { $0.state == .unknown })
        // The readings after the gap resume normally.
        #expect(result[45].percent == 52)
        #expect(result[45].isObserved)
    }

    @Test("Bins before the first reading of all are unknown, not zero and not on the pack")
    func nothingYet() {
        let result = bins([row(minutesBeforeNow: 20, percent: 41)])
        #expect(result[0].percent == nil)
        #expect(result[0].state == .unknown)
        #expect(result[0].isObserved == false)
        #expect(result[46].percent == nil)
        #expect(result[46].state == .unknown)
        #expect(result[47].percent == 41)
        #expect(result[47].isObserved)
    }

    @Test("A reading just older than the window seeds the carry without becoming a bin of its own")
    func seededFromBeforeTheWindow() {
        let result = bins([
            row(minutesBeforeNow: beforeWindow(20), percent: 64),   // 20 min before bin 0
            row(minutesBeforeNow: 10, percent: 55)
        ])
        // Bin 0 ends 50 minutes after the seed and takes it; bin 1 ends 80
        // minutes after it and does not.
        #expect(result[0].percent == 64)
        #expect(result[0].isObserved == false)
        #expect(result[1].percent == nil)
        #expect(result[1].state == .unknown)
        #expect(result[46].percent == nil)
        #expect(result[47].percent == 55)
    }

    @Test("A seed from days before the window does not paint the window")
    func staleSeedDoesNotCarry() {
        let result = bins([
            row(minutesBeforeNow: 3 * 24 * 60, percent: 64, charging: true, external: true),
            row(minutesBeforeNow: 10, percent: 55)
        ])
        #expect(result[0].percent == nil)
        #expect(result[0].state == .unknown)
        #expect(result[46].state == .unknown)
        #expect(result[47].percent == 55)
    }

    // MARK: - State

    @Test("State is the majority of the bin's readings weighted by time, not by count")
    func stateMajorityByTime() {
        // Bin 47 (the last 27 minutes): three readings crowded into the first
        // two minutes on the wall, then one on battery that holds for 25.
        // By count the mains readings win 3:1; by time the battery does.
        let result = bins([
            row(minutesBeforeNow: 27, percent: 90, external: true),
            row(minutesBeforeNow: 26, percent: 90, external: true),
            row(minutesBeforeNow: 25, percent: 90, external: true),
            row(minutesBeforeNow: 24, percent: 89)
        ])
        #expect(result[47].state == .battery)

        // The same readings with the discharge first: mains then holds.
        let flipped = bins([
            row(minutesBeforeNow: 27, percent: 89),
            row(minutesBeforeNow: 26, percent: 90, external: true),
            row(minutesBeforeNow: 25, percent: 90, external: true),
            row(minutesBeforeNow: 24, percent: 90, external: true)
        ])
        #expect(flipped[47].state == .mains)
    }

    @Test("The three states: charging, mains and battery")
    func threeStates() {
        let result = bins([
            row(minutesBeforeNow: 100, percent: 60, charging: true, external: true),
            row(minutesBeforeNow: 70, percent: 80, external: true),
            row(minutesBeforeNow: 40, percent: 80),
            row(minutesBeforeNow: 10, percent: 76)
        ])
        #expect(result[44].state == .charging)
        #expect(result[45].state == .mains)
        #expect(result[46].state == .battery)
        #expect(result[47].state == .battery)
        // Nothing at all precedes bin 10, so it has nothing to inherit — and
        // "no reading" is not "on the pack".
        #expect(result[10].state == .unknown)
        #expect(result[10].percent == nil)
    }

    @Test("A silent bin inherits the state before it while the silence is short")
    func carriedState() {
        // Plugged in and holding, then twenty minutes of quiet: the state and
        // the level both hold across it.
        let result = bins([
            row(minutesBeforeNow: 90, percent: 90, external: true),
            row(minutesBeforeNow: 80, percent: 90, external: true),
            row(minutesBeforeNow: 10, percent: 90, external: true)
        ])
        // 44 and 45 hold the two readings; 46 is the quiet between them and the
        // one that comes next.
        #expect(result[44].state == .mains)
        #expect(result[45].state == .mains)
        #expect(result[46].state == .mains)
        #expect(result[46].percent == 90)
        #expect(result[46].isObserved == false)
        // Still nothing invented: the hole measured no watts and reports none.
        #expect(result[46].powerInW == nil)
        #expect(result[46].systemLoadW == nil)
    }

    @Test("A Mac that slept on its charger keeps mains across the whole night")
    func sleptOnTheCharger() {
        // Plugged in and holding at 22:00, the lid closes, and the machine says
        // nothing for nearly ten hours. The app recorded both ends of that, so
        // the night is neither a discharge nor a hole.
        let rows = [
            row(minutesBeforeNow: 600, percent: 90, external: true),
            row(minutesBeforeNow: 590, percent: 90, external: true),
            row(minutesBeforeNow: 10, percent: 90, external: true)
        ]
        let markers = [marker(minutesBeforeNow: 585, .sleep), marker(minutesBeforeNow: 15, .wake)]
        let result = bins(rows, markers: markers)
        // 27 and 28 hold the two evening readings; 29...46 are the slept night.
        #expect(result[28].state == .mains)
        #expect(result[29...46].allSatisfy { $0.state == .mains })
        #expect(result[29...46].allSatisfy { $0.percent == 90 })
        #expect(result[29...46].allSatisfy { !$0.isObserved })
        #expect(result[35].powerInW == nil)

        // The same night with no markers is exactly what it looks like from
        // the data alone: hours nobody watched.
        let unwitnessed = bins(rows)
        #expect(unwitnessed[29].state == .mains)          // still inside the hour
        #expect(unwitnessed[32...46].allSatisfy { $0.state == .unknown })
        #expect(unwitnessed[32...46].allSatisfy { $0.percent == nil })
    }

    @Test("A sleep gap the machine was carried off through is still a hole")
    func sleptOffTheCharger() {
        // Markers on both ends, but the machine went to sleep on the pack: the
        // bracket says where it went, not that anything held its level.
        let result = bins(
            [
                row(minutesBeforeNow: 600, percent: 90),
                row(minutesBeforeNow: 10, percent: 62)
            ],
            markers: [marker(minutesBeforeNow: 595, .sleep), marker(minutesBeforeNow: 15, .wake)]
        )
        #expect(result[32...46].allSatisfy { $0.state == .unknown })
        #expect(result[32...46].allSatisfy { $0.percent == nil })
        #expect(result[47].percent == 62)
    }

    @Test("The carried state is seeded from the newest reading before the window")
    func stateSeededFromBeforeTheWindow() {
        let result = bins([
            row(minutesBeforeNow: beforeWindow(20), percent: 64, charging: true, external: true),
            row(minutesBeforeNow: 10, percent: 80)
        ])
        #expect(result[0].state == .charging)
        #expect(result[1].state == .unknown)
        #expect(result[46].state == .unknown)
        #expect(result[47].state == .battery)
    }

    @Test("A lone reading on the very edge of its bin still decides the bin")
    func singleReadingTie() {
        // One reading, right at the bin's left edge, and nothing after it in
        // the bin: every weight is zero and the tie goes to the last reading.
        let result = bins([row(minutesBeforeNow: 57, percent: 44, charging: true, external: true)])
        #expect(result[46].state == .charging)
    }

    // MARK: - Power

    @Test("powerInW and systemLoadW are means over the readings that carried one")
    func means() {
        let result = bins([
            row(minutesBeforeNow: 55, percent: 70, charging: true, external: true, powerIn: 60, load: 20),
            row(minutesBeforeNow: 45, percent: 74, charging: true, external: true, powerIn: 40, load: 30),
            // No telemetry at all: it must not drag the mean towards zero.
            row(minutesBeforeNow: 35, percent: 76, charging: true, external: true)
        ])
        #expect(result[46].powerInW == 50)
        #expect(result[46].systemLoadW == 25)
        #expect(result[47].powerInW == nil)
        #expect(result[47].systemLoadW == nil)
    }

    // MARK: - The store

    @Test("A v4 file migrates to v5 and its rows read back with an unknown power_in_w")
    func migrationV4toV5() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")

        // A file exactly as v4 left it: the v1 table plus system_load_w, and
        // meta.version saying 4.
        do {
            let database = try SQLiteDatabase(url: url)
            try database.execute("""
                CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE readings (
                    ts REAL NOT NULL, device TEXT NOT NULL, percent INTEGER NOT NULL,
                    is_charging INTEGER NOT NULL, external INTEGER NOT NULL,
                    fully_charged INTEGER NOT NULL, watts REAL, adapter_watts INTEGER,
                    raw_current_mah INTEGER, raw_max_mah INTEGER, design_mah INTEGER,
                    cycle_count INTEGER, temperature_c REAL,
                    is_partial INTEGER NOT NULL DEFAULT 0,
                    transport TEXT NOT NULL DEFAULT 'local',
                    system_load_w REAL
                );
                CREATE INDEX idx_readings_device_ts ON readings (device, ts);
                CREATE TABLE devices (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, last_seen REAL NOT NULL);
                CREATE TABLE sessions (
                    device TEXT NOT NULL, start REAL NOT NULL, end REAL,
                    from_percent INTEGER NOT NULL, to_percent INTEGER NOT NULL,
                    peak_watts REAL, average_watts REAL, adapter_watts INTEGER,
                    reached_80_at REAL, energy_wh REAL, PRIMARY KEY (device, start)
                );
                CREATE TABLE markers (ts REAL NOT NULL, kind TEXT NOT NULL, PRIMARY KEY (ts, kind));
                INSERT INTO meta (key, value) VALUES ('version','4');
                INSERT INTO readings (ts, device, percent, is_charging, external, fully_charged, system_load_w)
                VALUES (\(now.timeIntervalSince1970 - 3600), 'mac', 61, 0, 0, 0, 18.5);
                """)
        }

        let store = HistoryStore(url: url)
        try await store.prepare()
        #expect(try await store.storedSchemaVersion() == 5)
        #expect(HistoryStore.schemaVersion == 5)

        // The row written under v4 survives, and its new column is *unknown*
        // rather than zero.
        let old = try await store.readings(device: "mac")
        #expect(old.count == 1)
        #expect(old.first?.percent == 61)
        #expect(old.first?.systemLoadW == 18.5)
        #expect(old.first?.powerInW == nil)

        // And a row written after the migration keeps its figure.
        _ = try await store.record(row(minutesBeforeNow: 0, percent: 62, external: true, powerIn: 13.3, load: 12.1))
        let fresh = try await store.readings(device: "mac").last
        #expect(fresh?.powerInW == 13.3)
        #expect(fresh?.systemLoadW == 12.1)
    }

    @Test("The summary carries 48 bins whose last one ends at now")
    func summaryBins() async throws {
        let directory = HistoryFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
        try await store.noteDevice(id: "mac", kind: .mac, name: "MacBook Pro", lastSeen: now)

        // Six hours of Mac, one reading every ten minutes: two hours charging,
        // two on the wall at 90 %, two on battery.
        for step in 0..<36 {
            let minutesBeforeNow = 350 - Double(step) * 10
            let charging = minutesBeforeNow > 230
            let mains = !charging && minutesBeforeNow > 110
            _ = try await store.record(row(
                minutesBeforeNow: minutesBeforeNow,
                percent: charging ? 60 + Int((350 - minutesBeforeNow) / 4) : (mains ? 90 : 84),
                charging: charging,
                external: charging || mains,
                powerIn: charging ? 60 : (mains ? 13 : nil),
                load: 12
            ))
        }

        let history = try await store.summary(for: "mac", now: now, calendar: calendar)
        let bins = try #require(history?.bins24h)
        #expect(bins.count == 48)
        #expect(bins.last?.start == now.addingTimeInterval(-27 * 60))
        #expect(bins.contains { $0.state == .charging })
        #expect(bins.contains { $0.state == .mains })
        #expect(bins.contains { $0.state == .battery })
        // The series the widget reads is still there, untouched.
        #expect(history?.series.isEmpty == false)
    }

    // MARK: - JSON

    @Test("Bins survive a round-trip, and a summary written before they existed still decodes")
    func json() throws {
        let history = DeviceHistory(
            device: "mac", kind: .mac, name: "MacBook Pro", lastSeen: now, percent: 90,
            bins24h: bins([
                row(minutesBeforeNow: 40, percent: 90, external: true, powerIn: 13, load: 12),
                row(minutesBeforeNow: 5, percent: 89, load: 30)
            ])
        )
        let data = try HistoryStore.encoder.encode(history)
        let back = try HistoryStore.decoder.decode(DeviceHistory.self, from: data)
        #expect(back == history)
        #expect(back.bins24h.count == 48)

        // A `history-summary.json` from a build that had never heard of bins:
        // the field is absent, and the summary still decodes.
        let old = Data("""
            {"device":"mac","kind":"mac","name":"MacBook Pro","percent":90,"week":[],"series":[]}
            """.utf8)
        let decoded = try HistoryStore.decoder.decode(DeviceHistory.self, from: old)
        #expect(decoded.bins24h.isEmpty)
        #expect(decoded.percent == 90)

        // And one bin with every optional missing but `start`.
        let bare = try HistoryStore.decoder.decode(
            HistoryBin.self,
            from: Data(#"{"start":"2026-09-08T12:00:00Z"}"#.utf8)
        )
        #expect(bare.percent == nil)
        #expect(bare.state == .battery)
        #expect(bare.powerInW == nil)
        #expect(bare.isObserved == false)

        // A state a newer build invented decodes as `unknown` — "we do not
        // know" — rather than as `battery` and rather than throwing the whole
        // file away.
        let future = try HistoryStore.decoder.decode(
            HistoryBin.self,
            from: Data(#"{"start":"2026-09-08T12:00:00Z","state":"wireless","percent":44}"#.utf8)
        )
        #expect(future.state == .unknown)
        #expect(future.percent == 44)
    }

    @Test("An unknown bin round-trips, and a file written before isObserved existed decodes")
    func unknownJSON() throws {
        // Ten hours of silence after one reading: most of the window is
        // unknown, and it has to survive the file.
        let history = DeviceHistory(
            device: "mac", kind: .mac, name: "MacBook Pro", lastSeen: now, percent: 76,
            bins24h: bins([row(minutesBeforeNow: 700, percent: 76, external: true)])
        )
        #expect(history.bins24h.contains { $0.state == .unknown })
        let data = try HistoryStore.encoder.encode(history)
        // The new state travels as its own name, not as an absent key.
        #expect(String(decoding: data, as: UTF8.self).contains("\"unknown\""))
        let back = try HistoryStore.decoder.decode(DeviceHistory.self, from: data)
        #expect(back == history)
        #expect(back.bins24h.filter { $0.state == .unknown }.count
                == history.bins24h.filter { $0.state == .unknown }.count)
        #expect(back.bins24h.contains { $0.isObserved })

        // A bin written by a build that had the states but not the flag: it
        // decodes, and says it cannot vouch for the reading.
        let old = try HistoryStore.decoder.decode(
            HistoryBin.self,
            from: Data(#"{"start":"2026-09-08T12:00:00Z","state":"mains","percent":90,"powerInW":13}"#.utf8)
        )
        #expect(old.state == .mains)
        #expect(old.percent == 90)
        #expect(old.powerInW == 13)
        #expect(old.isObserved == false)

        // And an explicit `isObserved` is read back as written.
        let observed = try HistoryStore.decoder.decode(
            HistoryBin.self,
            from: Data(#"{"start":"2026-09-08T12:00:00Z","state":"unknown","isObserved":false}"#.utf8)
        )
        #expect(observed.state == .unknown)
        #expect(observed.percent == nil)
    }
}
