import Foundation

/// The local battery history: an append-mostly log of readings in a SQLite file,
/// plus the sessions materialised from it.
///
/// Neither macOS nor iOS hands us any history at all — every reading we will
/// ever have is one we took ourselves — so this is the only place a "last charge
/// session" or a 24 h chart can come from. See NOTES.md §15 for the schema, the
/// skip rule and the retention policy.
///
/// Foundation plus the system SQLite (`import SQLite3`) and nothing else: the
/// widget extension has to be able to link this.
public actor HistoryStore {

    // MARK: - Knobs

    /// Bumped whenever the schema changes; `migrate()` walks from whatever the
    /// file says up to this. v1 was `meta` + `readings`; v2 added `devices` and
    /// `sessions`; v3 added `markers` (sleep/wake, NOTES.md §15.7); v4 added
    /// the nullable `readings.system_load_w`.
    public static let schemaVersion = 4

    /// How many `system_load_w` samples `summary` carries for the sparkline.
    public static let systemLoadSeriesLimit = 12

    /// A `capacityTrend` shorter than this is not a trend, it is noise: the
    /// gauge's full-charge figure wanders by tens of mAh between charges.
    public static let capacityTrendMinimumSpan: TimeInterval = 7 * 24 * 60 * 60

    /// The 24 h chart is capped at 15-minute resolution.
    public static let seriesPointLimit = 96

    public nonisolated let url: URL
    /// Raw rows older than this are deleted by `prune()`. 30 days.
    public nonisolated let retention: TimeInterval
    /// A materially unchanged reading is still written once this much time has
    /// passed, so an idle week is 6 rows an hour rather than nothing at all.
    public nonisolated let idleInterval: TimeInterval
    /// Wattage difference below which two rows count as unchanged.
    public nonisolated let wattTolerance: Double
    /// `record` prunes at most this often.
    public nonisolated let pruneInterval: TimeInterval

    private var database: SQLiteDatabase?

    public init(
        url: URL = HistoryStore.defaultURL,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        idleInterval: TimeInterval = 10 * 60,
        wattTolerance: Double = 0.5,
        pruneInterval: TimeInterval = 24 * 60 * 60
    ) {
        self.url = url
        self.retention = retention
        self.idleInterval = idleInterval
        self.wattTolerance = wattTolerance
        self.pruneInterval = pruneInterval
    }

    /// `~/Library/Application Support/Tandem/history.sqlite`.
    ///
    /// The app should override this with its App Group container so the widget
    /// can open the same file — the same move `SnapshotStore` needs (NOTES.md §7).
    public nonisolated static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Tandem/history.sqlite")
    }

    // MARK: - Opening and migrating

    /// Opens on first use so `init` cannot fail and tests can build a store for
    /// a path that does not exist yet.
    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let database = try SQLiteDatabase(url: url)
        // WAL: a reader (the widget, `tandemctl history`) never blocks the
        // writer, and a crash mid-write cannot corrupt the file.
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA synchronous=NORMAL")
        try database.execute("PRAGMA foreign_keys=ON")
        try migrate(database)
        self.database = database
        return database
    }

    /// Force the file open (and migrated) without writing anything.
    public func prepare() throws {
        _ = try open()
    }

    /// `"wal"` once the store has been opened.
    public func journalMode() throws -> String {
        let database = try open()
        return try database.scalarText("PRAGMA journal_mode") ?? ""
    }

    /// The `meta.version` the file carries.
    public func storedSchemaVersion() throws -> Int {
        let database = try open()
        return try Self.readVersion(database)
    }

    private static func readVersion(_ database: SQLiteDatabase) throws -> Int {
        try database.execute("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let statement = try database.prepare("SELECT value FROM meta WHERE key='version'")
        defer { statement.finalize() }
        guard try statement.step(), let text = statement.string(0), let value = Int(text) else { return 0 }
        return value
    }

    private static func writeVersion(_ database: SQLiteDatabase, _ version: Int) throws {
        try database.execute("INSERT INTO meta (key, value) VALUES ('version','\(version)') ON CONFLICT(key) DO UPDATE SET value=excluded.value")
    }

    private func migrate(_ database: SQLiteDatabase) throws {
        try database.transaction {
            var version = try Self.readVersion(database)
            if version == 0 {
                try Self.createV1(database)
                version = 1
                try Self.writeVersion(database, version)
            }
            if version == 1 {
                try Self.migrateV1toV2(database)
                version = 2
                try Self.writeVersion(database, version)
            }
            if version == 2 {
                try Self.migrateV2toV3(database)
                version = 3
                try Self.writeVersion(database, version)
            }
            if version == 3 {
                try Self.migrateV3toV4(database)
                version = 4
                try Self.writeVersion(database, version)
            }
            // A newer file than this build understands: leave it alone. Every
            // column added since is nullable, so the reads below still work.
        }
    }

    /// v1: the reading log and its only index.
    private static func createV1(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS readings (
                ts REAL NOT NULL,
                device TEXT NOT NULL,
                percent INTEGER NOT NULL,
                is_charging INTEGER NOT NULL,
                external INTEGER NOT NULL,
                fully_charged INTEGER NOT NULL,
                watts REAL,
                adapter_watts INTEGER,
                raw_current_mah INTEGER,
                raw_max_mah INTEGER,
                design_mah INTEGER,
                cycle_count INTEGER,
                temperature_c REAL,
                is_partial INTEGER NOT NULL DEFAULT 0,
                transport TEXT NOT NULL DEFAULT 'local'
            );
            CREATE INDEX IF NOT EXISTS idx_readings_device_ts ON readings (device, ts);
            """)
    }

    /// v2: the device book (so `--device iphone` resolves and the summary can
    /// carry a name) and the materialised sessions.
    private static func migrateV1toV2(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS devices (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                name TEXT NOT NULL,
                last_seen REAL NOT NULL
            );
            CREATE TABLE IF NOT EXISTS sessions (
                device TEXT NOT NULL,
                start REAL NOT NULL,
                end REAL,
                from_percent INTEGER NOT NULL,
                to_percent INTEGER NOT NULL,
                peak_watts REAL,
                average_watts REAL,
                adapter_watts INTEGER,
                reached_80_at REAL,
                energy_wh REAL,
                PRIMARY KEY (device, start)
            );
            CREATE INDEX IF NOT EXISTS idx_sessions_device_start ON sessions (device, start);
            """)
    }

    /// v3: sleep/wake markers. Not per-device on purpose — it is *this Mac*
    /// that sleeps, and while it does neither battery is being read, so the
    /// marker applies to every device in the file.
    private static func migrateV2toV3(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE TABLE IF NOT EXISTS markers (
                ts REAL NOT NULL,
                kind TEXT NOT NULL,
                PRIMARY KEY (ts, kind)
            );
            CREATE INDEX IF NOT EXISTS idx_markers_ts ON markers (ts);
            """)
    }

    /// v4: what the machine itself was drawing at each reading
    /// (`PowerTelemetryData.SystemLoad`), for the summary window's sparkline.
    ///
    /// A plain `ALTER TABLE … ADD COLUMN`, nullable and with no default, so
    /// every row written before this migration reads back as "unknown" rather
    /// than as a machine that drew nothing — the §15.1 rule. Nothing is
    /// rewritten and no index changes, so the migration costs the same whatever
    /// the file weighs.
    private static func migrateV3toV4(_ database: SQLiteDatabase) throws {
        try database.execute("ALTER TABLE readings ADD COLUMN system_load_w REAL")
    }

    // MARK: - Recording

    /// Record one row per device present in the snapshot.
    ///
    /// Returns how many rows were actually written — 0, 1 or 2, since the skip
    /// rule drops a device whose reading has not materially changed.
    @discardableResult
    public func record(_ snapshot: TandemSnapshot, now: Date = Date()) throws -> Int {
        var written = 0
        for status in [snapshot.mac, snapshot.phone].compactMap({ $0 }) {
            let reading = status.reading
            try noteDevice(id: reading.deviceID, kind: reading.kind, name: reading.name, lastSeen: reading.timestamp)
            if try record(HistoryReading(status: status)) { written += 1 }
        }
        try pruneIfDue(now: now)
        return written
    }

    /// Record one row, applying the skip rule.
    ///
    /// A row is written when *anything material* changed since the previous row
    /// for this device — percent, charging, external, fullyCharged, or the
    /// wattage by more than `wattTolerance` — or when `idleInterval` has passed
    /// since that row. Rows older than the newest one are refused outright, so a
    /// late-arriving reading cannot corrupt the series.
    ///
    /// Returns `true` when a row was written.
    @discardableResult
    public func record(_ row: HistoryReading) throws -> Bool {
        let database = try open()
        let previous = try latestReading(database, device: row.device)
        if let previous {
            if row.timestamp <= previous.timestamp { return false }
            if row.isMateriallySame(as: previous, wattTolerance: wattTolerance),
               row.timestamp.timeIntervalSince(previous.timestamp) < idleInterval {
                return false
            }
        }

        let statement = try database.prepare("""
            INSERT INTO readings
              (ts, device, percent, is_charging, external, fully_charged, watts, adapter_watts,
               raw_current_mah, raw_max_mah, design_mah, cycle_count, temperature_c, is_partial, transport,
               system_load_w)
            VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)
            """)
        defer { statement.finalize() }
        statement.bind(1, row.timestamp.timeIntervalSince1970)
        statement.bind(2, row.device)
        statement.bind(3, row.percent)
        statement.bind(4, row.isCharging)
        statement.bind(5, row.externalConnected)
        statement.bind(6, row.fullyCharged)
        statement.bind(7, row.watts)
        statement.bind(8, row.adapterWatts)
        statement.bind(9, row.rawCurrentMAh)
        statement.bind(10, row.rawMaxMAh)
        statement.bind(11, row.designMAh)
        statement.bind(12, row.cycleCount)
        statement.bind(13, row.temperatureC)
        statement.bind(14, row.isPartial)
        statement.bind(15, row.transport.rawValue)
        statement.bind(16, row.systemLoadW)
        try statement.step()

        // Keep `sessions` current. Only the stretch back to the last reading
        // that was *off* external power can have changed, so that is all we
        // rebuild — no 30-day rescan per poll.
        try rebuildSessions(database, device: row.device, anchoredBefore: row.timestamp)
        return true
    }

    /// Remember a device id so `--device iphone` and the summary's name work.
    public func noteDevice(id: String, kind: DeviceKind, name: String, lastSeen: Date) throws {
        let database = try open()
        let statement = try database.prepare("""
            INSERT INTO devices (id, kind, name, last_seen) VALUES (?1,?2,?3,?4)
            ON CONFLICT(id) DO UPDATE SET
              kind=excluded.kind,
              name=CASE WHEN excluded.name='' THEN devices.name ELSE excluded.name END,
              last_seen=MAX(devices.last_seen, excluded.last_seen)
            """)
        defer { statement.finalize() }
        statement.bind(1, id)
        statement.bind(2, kind.rawValue)
        statement.bind(3, name)
        statement.bind(4, lastSeen.timeIntervalSince1970)
        try statement.step()
    }

    // MARK: - Sleep and wake (NOTES.md §15.7)

    /// Note that the machine is about to sleep.
    ///
    /// Call it from `NSWorkspace.willSleepNotification`. On its own it changes
    /// nothing; paired with `recordWake(at:)` it is what stops a Mac that slept
    /// on the charger from being booked as two charge sessions.
    public func recordSleep(at date: Date = Date()) throws {
        try record(SleepMarker(timestamp: date, kind: .sleep))
    }

    /// Note that the machine has woken. Call it from
    /// `NSWorkspace.didWakeNotification`, *before* the poll that follows.
    ///
    /// Sessions are re-derived for every device that was on external power when
    /// it went quiet, so the summary is right immediately rather than after the
    /// next reading lands.
    public func recordWake(at date: Date = Date()) throws {
        try record(SleepMarker(timestamp: date, kind: .wake))
        let database = try open()
        for device in try devices() {
            try rebuildSessions(database, device: device.id, anchoredBefore: nil)
        }
    }

    /// Store one marker. Two markers of the same kind at the same instant are
    /// the same marker (the primary key), so a duplicated notification costs
    /// nothing.
    public func record(_ marker: SleepMarker) throws {
        let database = try open()
        let statement = try database.prepare("INSERT OR REPLACE INTO markers (ts, kind) VALUES (?1,?2)")
        defer { statement.finalize() }
        statement.bind(1, marker.timestamp.timeIntervalSince1970)
        statement.bind(2, marker.kind.rawValue)
        try statement.step()
    }

    /// Markers in `[from, through]`, oldest first.
    public func markers(from: Date? = nil, through: Date? = nil) throws -> [SleepMarker] {
        try markers(try open(), from: from, through: through)
    }

    private func markers(_ database: SQLiteDatabase, from: Date?, through: Date?) throws -> [SleepMarker] {
        let statement = try database.prepare("""
            SELECT ts, kind FROM markers WHERE ts >= ?1 AND ts <= ?2 ORDER BY ts ASC
            """)
        defer { statement.finalize() }
        statement.bind(1, from?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        statement.bind(2, through?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)
        var result: [SleepMarker] = []
        while try statement.step() {
            guard let kind = SleepMarker.Kind(rawValue: statement.string(1) ?? "") else { continue }
            result.append(SleepMarker(timestamp: Date(timeIntervalSince1970: statement.double(0)), kind: kind))
        }
        return result
    }

    // MARK: - Retention

    /// Delete raw rows and finished sessions older than `retention`.
    /// Returns the number of `readings` rows deleted.
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        let database = try open()
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        let deleted = try database.transaction { () -> Int in
            let count = try scalarInt(database, "SELECT COUNT(*) FROM readings WHERE ts < ?1", cutoff)
            let readings = try database.prepare("DELETE FROM readings WHERE ts < ?1")
            defer { readings.finalize() }
            readings.bind(1, cutoff)
            try readings.step()

            let sessions = try database.prepare("DELETE FROM sessions WHERE COALESCE(end, start) < ?1")
            defer { sessions.finalize() }
            sessions.bind(1, cutoff)
            try sessions.step()

            let markers = try database.prepare("DELETE FROM markers WHERE ts < ?1")
            defer { markers.finalize() }
            markers.bind(1, cutoff)
            try markers.step()
            return count
        }
        try setMeta(database, "last_prune", String(now.timeIntervalSince1970))
        return deleted
    }

    private func pruneIfDue(now: Date) throws {
        let database = try open()
        let last = try getMeta(database, "last_prune").flatMap(Double.init) ?? 0
        guard now.timeIntervalSince1970 - last >= pruneInterval else { return }
        _ = try prune(now: now)
    }

    // MARK: - Sessions

    /// Re-derive every session for a device from the retained readings and
    /// replace the materialised rows. Public because a schema change or an
    /// import wants it; `record` uses the anchored form instead.
    @discardableResult
    public func rebuildSessions(device: String) throws -> [ChargeSession] {
        let database = try open()
        try rebuildSessions(database, device: device, anchoredBefore: nil)
        return try sessions(device: device)
    }

    /// Rebuild only the part of the timeline that could have changed.
    ///
    /// A session cannot span a reading that was off external power, so the last
    /// such reading before `anchoredBefore` is a safe cut: everything at or
    /// before it is settled. With no such reading (the whole history is one long
    /// charge) this falls back to a full rebuild.
    private func rebuildSessions(_ database: SQLiteDatabase, device: String, anchoredBefore: Date?) throws {
        var anchor: Double?
        if let anchoredBefore {
            let statement = try database.prepare("""
                SELECT ts FROM readings WHERE device=?1 AND ts < ?2 AND external=0 ORDER BY ts DESC LIMIT 1
                """)
            defer { statement.finalize() }
            statement.bind(1, device)
            statement.bind(2, anchoredBefore.timeIntervalSince1970)
            if try statement.step() { anchor = statement.double(0) }
        }

        let start = anchor.map { Date(timeIntervalSince1970: $0) }
        let rows = try readings(database, device: device, from: start, through: nil)
        // The markers covering the same stretch: a hole in `rows` that the app
        // told us was a sleep is not a break in the session (NOTES.md §15.7).
        let sleeps = try markers(database, from: start, through: nil)
        let derived = ChargeSessionBuilder.sessions(from: rows, device: device, markers: sleeps)

        try database.transaction {
            let delete = try database.prepare("DELETE FROM sessions WHERE device=?1 AND start >= ?2")
            defer { delete.finalize() }
            delete.bind(1, device)
            delete.bind(2, anchor ?? 0)
            try delete.step()

            let insert = try database.prepare("""
                INSERT OR REPLACE INTO sessions
                  (device, start, end, from_percent, to_percent, peak_watts, average_watts,
                   adapter_watts, reached_80_at, energy_wh)
                VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
                """)
            defer { insert.finalize() }
            for session in derived {
                insert.reset()
                insert.bind(1, session.device)
                insert.bind(2, session.start.timeIntervalSince1970)
                insert.bind(3, session.end?.timeIntervalSince1970)
                insert.bind(4, session.fromPercent)
                insert.bind(5, session.toPercent)
                insert.bind(6, session.peakWatts)
                insert.bind(7, session.averageWatts)
                insert.bind(8, session.adapterWatts)
                insert.bind(9, session.reached80At?.timeIntervalSince1970)
                insert.bind(10, session.energyWh)
                try insert.step()
            }
        }
    }

    /// Materialised sessions, newest first.
    public func sessions(device: String, limit: Int = 50) throws -> [ChargeSession] {
        let database = try open()
        let statement = try database.prepare("""
            SELECT device, start, end, from_percent, to_percent, peak_watts, average_watts,
                   adapter_watts, reached_80_at, energy_wh
            FROM sessions WHERE device=?1 ORDER BY start DESC LIMIT ?2
            """)
        defer { statement.finalize() }
        statement.bind(1, device)
        statement.bind(2, limit)
        var result: [ChargeSession] = []
        while try statement.step() {
            result.append(ChargeSession(
                device: statement.string(0) ?? device,
                start: Date(timeIntervalSince1970: statement.double(1)),
                end: statement.optionalDouble(2).map { Date(timeIntervalSince1970: $0) },
                fromPercent: statement.int(3),
                toPercent: statement.int(4),
                peakWatts: statement.optionalDouble(5),
                averageWatts: statement.optionalDouble(6),
                adapterWatts: statement.optionalInt(7),
                reached80At: statement.optionalDouble(8).map { Date(timeIntervalSince1970: $0) },
                energyWh: statement.optionalDouble(9)
            ))
        }
        return result
    }

    // MARK: - Reading back

    public func readings(device: String, from: Date? = nil, through: Date? = nil) throws -> [HistoryReading] {
        try readings(try open(), device: device, from: from, through: through)
    }

    public func readingCount(device: String? = nil) throws -> Int {
        let database = try open()
        if let device {
            return try scalarInt(database, "SELECT COUNT(*) FROM readings WHERE device=?1", device)
        }
        return try scalarInt(database, "SELECT COUNT(*) FROM readings", nil)
    }

    public func devices() throws -> [HistoryDevice] {
        let database = try open()
        let statement = try database.prepare("SELECT id, kind, name, last_seen FROM devices ORDER BY kind, id")
        defer { statement.finalize() }
        var result: [HistoryDevice] = []
        while try statement.step() {
            result.append(HistoryDevice(
                id: statement.string(0) ?? "",
                kind: DeviceKind(rawValue: statement.string(1) ?? "") ?? .mac,
                name: statement.string(2) ?? "",
                lastSeen: Date(timeIntervalSince1970: statement.double(3))
            ))
        }
        // Mac first, then phone — the order the summary view stacks them.
        return result.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .mac }
            return lhs.id < rhs.id
        }
    }

    /// Resolve `mac` / `iphone` (or a literal device id) to a device id.
    public func resolveDevice(_ token: String) throws -> HistoryDevice? {
        let known = try devices()
        if let kind = DeviceKind(rawValue: token.lowercased()) {
            return known.first { $0.kind == kind }
        }
        return known.first { $0.id == token }
    }

    public func dailyStats(device: String, days: Int = 7, now: Date = Date(), calendar: Calendar = .current) throws -> [DailyStat] {
        let start = calendar.startOfDay(for: now.addingTimeInterval(-Double(max(0, days - 1)) * 86_400))
        let rows = try readings(device: device, from: start, through: now)
        return ChargeSessionBuilder.dailyStats(from: rows, device: device, calendar: calendar)
    }

    private func readings(
        _ database: SQLiteDatabase,
        device: String,
        from: Date?,
        through: Date?
    ) throws -> [HistoryReading] {
        let statement = try database.prepare("""
            SELECT ts, device, percent, is_charging, external, fully_charged, watts, adapter_watts,
                   raw_current_mah, raw_max_mah, design_mah, cycle_count, temperature_c, is_partial, transport,
                   system_load_w
            FROM readings
            WHERE device=?1 AND ts >= ?2 AND ts <= ?3
            ORDER BY ts ASC
            """)
        defer { statement.finalize() }
        statement.bind(1, device)
        statement.bind(2, from?.timeIntervalSince1970 ?? -Double.greatestFiniteMagnitude)
        statement.bind(3, through?.timeIntervalSince1970 ?? Double.greatestFiniteMagnitude)
        var result: [HistoryReading] = []
        while try statement.step() {
            result.append(HistoryReading(
                timestamp: Date(timeIntervalSince1970: statement.double(0)),
                device: statement.string(1) ?? device,
                percent: statement.int(2),
                isCharging: statement.bool(3),
                externalConnected: statement.bool(4),
                fullyCharged: statement.bool(5),
                watts: statement.optionalDouble(6),
                adapterWatts: statement.optionalInt(7),
                rawCurrentMAh: statement.optionalInt(8),
                rawMaxMAh: statement.optionalInt(9),
                designMAh: statement.optionalInt(10),
                cycleCount: statement.optionalInt(11),
                temperatureC: statement.optionalDouble(12),
                isPartial: statement.bool(13),
                transport: Transport(rawValue: statement.string(14) ?? "") ?? .local,
                systemLoadW: statement.optionalDouble(15)
            ))
        }
        return result
    }

    private func latestReading(_ database: SQLiteDatabase, device: String) throws -> HistoryReading? {
        let statement = try database.prepare("""
            SELECT ts, device, percent, is_charging, external, fully_charged, watts, adapter_watts,
                   raw_current_mah, raw_max_mah, design_mah, cycle_count, temperature_c, is_partial, transport,
                   system_load_w
            FROM readings WHERE device=?1 ORDER BY ts DESC LIMIT 1
            """)
        defer { statement.finalize() }
        statement.bind(1, device)
        guard try statement.step() else { return nil }
        return HistoryReading(
            timestamp: Date(timeIntervalSince1970: statement.double(0)),
            device: statement.string(1) ?? device,
            percent: statement.int(2),
            isCharging: statement.bool(3),
            externalConnected: statement.bool(4),
            fullyCharged: statement.bool(5),
            watts: statement.optionalDouble(6),
            adapterWatts: statement.optionalInt(7),
            rawCurrentMAh: statement.optionalInt(8),
            rawMaxMAh: statement.optionalInt(9),
            designMAh: statement.optionalInt(10),
            cycleCount: statement.optionalInt(11),
            temperatureC: statement.optionalDouble(12),
            isPartial: statement.bool(13),
            transport: Transport(rawValue: statement.string(14) ?? "") ?? .local,
            systemLoadW: statement.optionalDouble(15)
        )
    }

    /// The newest row that came from a **full** read, i.e. the newest row whose
    /// health, cycle count and temperature are real numbers rather than
    /// "unknown" (NOTES.md §13.2).
    private func latestFullReading(_ database: SQLiteDatabase, device: String) throws -> HistoryReading? {
        let statement = try database.prepare("""
            SELECT ts FROM readings WHERE device=?1 AND is_partial=0 AND raw_max_mah IS NOT NULL
            ORDER BY ts DESC LIMIT 1
            """)
        defer { statement.finalize() }
        statement.bind(1, device)
        guard try statement.step() else { return nil }
        let ts = Date(timeIntervalSince1970: statement.double(0))
        return try readings(database, device: device, from: ts, through: ts).last
    }

    /// The last `limit` recorded system-load figures for a device, **oldest
    /// first**, skipping every reading that carried none.
    ///
    /// Straight off the `(device, ts)` index and capped at `limit`, so it costs
    /// the same on day 1 and on day 30. Rows with no telemetry are filtered in
    /// SQL rather than in Swift: an iPhone on battery reports nothing for hours
    /// at a stretch, and taking "the last 12 rows and then dropping the nulls"
    /// would hand back two points.
    public func systemLoadSeries(
        device: String,
        limit: Int = HistoryStore.systemLoadSeriesLimit
    ) throws -> [Double] {
        let database = try open()
        let statement = try database.prepare("""
            SELECT system_load_w FROM readings
            WHERE device=?1 AND system_load_w IS NOT NULL
            ORDER BY ts DESC LIMIT ?2
            """)
        defer { statement.finalize() }
        statement.bind(1, device)
        statement.bind(2, max(0, limit))
        var newestFirst: [Double] = []
        while try statement.step() {
            newestFirst.append(statement.double(0))
        }
        return newestFirst.reversed()
    }

    /// How the full-charge capacity has moved between the oldest and the newest
    /// **full** reading we still hold for a device.
    ///
    /// `nil` when there are fewer than two such readings, or when they are less
    /// than `minimumSpan` apart — a UI that cannot say "over N days" honestly
    /// should say nothing at all rather than draw a placeholder.
    public func capacityTrend(
        device: String,
        minimumSpan: TimeInterval = HistoryStore.capacityTrendMinimumSpan
    ) throws -> CapacityTrend? {
        let database = try open()
        func edge(_ order: String) throws -> (Date, Int)? {
            let statement = try database.prepare("""
                SELECT ts, raw_max_mah FROM readings
                WHERE device=?1 AND is_partial=0 AND raw_max_mah IS NOT NULL AND raw_max_mah > 0
                ORDER BY ts \(order) LIMIT 1
                """)
            defer { statement.finalize() }
            statement.bind(1, device)
            guard try statement.step() else { return nil }
            return (Date(timeIntervalSince1970: statement.double(0)), statement.int(1))
        }
        guard let first = try edge("ASC"), let last = try edge("DESC") else { return nil }
        let trend = CapacityTrend(firstMAh: first.1, lastMAh: last.1, first: first.0, last: last.0)
        return trend.span >= minimumSpan ? trend : nil
    }

    // MARK: - Summary

    /// Everything the summary view and the large widget need, for every device
    /// we have ever recorded.
    public func summary(now: Date = Date(), calendar: Calendar = .current) throws -> HistorySummary {
        let known = try devices()
        var entries: [DeviceHistory] = []
        for device in known {
            entries.append(try summary(for: device.id, now: now, calendar: calendar) ?? DeviceHistory(
                device: device.id, kind: device.kind, name: device.name, lastSeen: device.lastSeen
            ))
        }
        return HistorySummary(generatedAt: now, devices: entries)
    }

    /// The summary for one device id. `nil` when nothing has ever been recorded
    /// for it.
    public func summary(for device: String, now: Date = Date(), calendar: Calendar = .current) throws -> DeviceHistory? {
        let database = try open()
        let known = try devices().first { $0.id == device }
        guard let latest = try latestReading(database, device: device) else {
            guard let known else { return nil }
            return DeviceHistory(device: device, kind: known.kind, name: known.name, lastSeen: known.lastSeen)
        }

        let full = try latestFullReading(database, device: device)
        let health: BatteryHealth? = {
            guard let full, let rawMax = full.rawMaxMAh, let design = full.designMAh, design > 0 else { return nil }
            return BatteryHealth(rawMaxMAh: rawMax, designMAh: design)
        }()

        let weekStart = calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400))
        let window = try readings(database, device: device, from: weekStart, through: now)
        let stats = ChargeSessionBuilder.dailyStats(from: window, device: device, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let series = ChargeSessionBuilder.downsample(
            window.filter { $0.timestamp >= dayStart },
            from: dayStart,
            through: now,
            limit: Self.seriesPointLimit
        )

        return DeviceHistory(
            device: device,
            kind: known?.kind,
            name: known?.name,
            lastSeen: latest.timestamp,
            health: health,
            cycleCount: full?.cycleCount,
            temperatureC: full?.temperatureC,
            percent: latest.percent,
            isCharging: latest.isCharging,
            lastSession: try sessions(device: device, limit: 1).first,
            today: stats.first { calendar.isDate($0.day, inSameDayAs: today) },
            week: stats,
            series: series,
            systemLoadSeries: try systemLoadSeries(device: device)
        )
    }

    /// Pretty-printed, key-sorted, ISO-8601 JSON — the same shape
    /// `SnapshotStore` writes, so the app can drop this next to `snapshot.json`
    /// in the App Group container and the widget reads both the same way.
    public func encodeSummary(_ summary: HistorySummary) throws -> Data {
        try Self.encoder.encode(summary)
    }

    @discardableResult
    public func writeSummary(to url: URL, now: Date = Date(), calendar: Calendar = .current) throws -> HistorySummary {
        let summary = try summary(now: now, calendar: calendar)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(summary).write(to: url, options: [.atomic])
        return summary
    }

    public nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    public nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Small helpers

    private func scalarInt(_ database: SQLiteDatabase, _ sql: String, _ argument: Any?) throws -> Int {
        let statement = try database.prepare(sql)
        defer { statement.finalize() }
        switch argument {
        case let value as Double: statement.bind(1, value)
        case let value as String: statement.bind(1, value)
        case let value as Int: statement.bind(1, value)
        default: break
        }
        guard try statement.step() else { return 0 }
        return statement.int(0)
    }

    private func getMeta(_ database: SQLiteDatabase, _ key: String) throws -> String? {
        let statement = try database.prepare("SELECT value FROM meta WHERE key=?1")
        defer { statement.finalize() }
        statement.bind(1, key)
        guard try statement.step() else { return nil }
        return statement.string(0)
    }

    private func setMeta(_ database: SQLiteDatabase, _ key: String, _ value: String) throws {
        let statement = try database.prepare("""
            INSERT INTO meta (key, value) VALUES (?1,?2)
            ON CONFLICT(key) DO UPDATE SET value=excluded.value
            """)
        defer { statement.finalize() }
        statement.bind(1, key)
        statement.bind(2, value)
        try statement.step()
    }
}
