import Foundation

/// A reading plus everything derived from it, ready to render.
public struct DeviceStatus: Sendable, Codable, Equatable {
    public var reading: BatteryReading
    public var etaTo80: TimeInterval?
    /// The wall-clock moment `etaTo80` points at, fixed when the reading was
    /// taken (`lastSeen + etaTo80`).
    ///
    /// A UI can count down to this between polls — `Text(timerInterval:)`, a
    /// `TimelineView`, or one extra widget entry per minute — instead of
    /// polling the phone to keep "80 % · N min" moving. It is `nil` whenever
    /// `etaTo80` is, and it survives the partial-reading merge unchanged (a
    /// carried-over ETA must not slide forward just because a newer percent
    /// arrived). Absent from JSON written before it existed, where it is
    /// reconstructed from `lastSeen + etaTo80` on decode.
    public var etaTo80At: Date?
    public var timeToEmpty: TimeInterval?
    public var chargingWatts: Double?
    /// When this reading was actually obtained.
    public var lastSeen: Date
    /// True when `lastSeen` is older than the monitor's staleness window, i.e.
    /// we are showing the last thing we know rather than something current.
    public var isStale: Bool
    /// Seconds since the last **full** reading, when the newest reading is
    /// partial (NOTES.md §13).
    ///
    /// `nil` means the numbers on show are all as fresh as `lastSeen`. When it
    /// is set, `reading.percent`, `isCharging` and `externalConnected` are
    /// current as of `lastSeen`, while the watt, adapter, temperature and ETA
    /// columns come from a full read this many seconds ago — dim them.
    public var detailAge: TimeInterval?
    /// Why the last poll for this device failed, if it did, while an older
    /// reading is still being shown. `nil` on a healthy status.
    public var error: MonitorError?

    /// True when the newest reading came from the degraded tier.
    public var isPartial: Bool { reading.isPartial }

    public init(
        reading: BatteryReading,
        etaTo80: TimeInterval? = nil,
        timeToEmpty: TimeInterval? = nil,
        chargingWatts: Double? = nil,
        lastSeen: Date,
        isStale: Bool = false,
        detailAge: TimeInterval? = nil,
        error: MonitorError? = nil,
        etaTo80At: Date? = nil
    ) {
        self.reading = reading
        self.etaTo80 = etaTo80
        // Rounded to the second: the deadline is rendered in minutes, and the
        // store's ISO-8601 encoding has second resolution, so keeping the
        // estimator's fractional tail would only make a snapshot fail to
        // round-trip through its own JSON.
        self.etaTo80At = etaTo80At ?? etaTo80.map { lastSeen.addingTimeInterval($0.rounded()) }
        self.timeToEmpty = timeToEmpty
        self.chargingWatts = chargingWatts
        self.lastSeen = lastSeen
        self.isStale = isStale
        self.detailAge = detailAge
        self.error = error
    }

    public init(
        reading: BatteryReading,
        estimate: ChargeEstimate,
        lastSeen: Date,
        isStale: Bool = false,
        detailAge: TimeInterval? = nil,
        error: MonitorError? = nil
    ) {
        self.init(
            reading: reading,
            etaTo80: estimate.etaTo80,
            timeToEmpty: estimate.timeToEmpty,
            chargingWatts: estimate.chargingWatts,
            lastSeen: lastSeen,
            isStale: isStale,
            detailAge: detailAge,
            error: error
        )
    }

    /// Seconds still to run before `etaTo80At`, clamped at zero.
    ///
    /// `nil` when there is no charge ETA at all. Zero means the 80 % target has
    /// been reached (or passed) since the reading — render "charged"/"80 %",
    /// never a negative or a stale count.
    public func timeTo80(now: Date = Date()) -> TimeInterval? {
        guard let etaTo80At else { return etaTo80 }
        return max(0, etaTo80At.timeIntervalSince(now))
    }

    /// True once the 80 % deadline has come and gone.
    public func reached80(now: Date = Date()) -> Bool {
        guard let etaTo80At else { return false }
        return etaTo80At <= now
    }

    private enum CodingKeys: String, CodingKey {
        case reading, etaTo80, timeToEmpty, chargingWatts, lastSeen
        case isStale = "stale"
        case detailAge, error, etaTo80At
    }

    /// Hand-written only so a snapshot written before `etaTo80At` existed still
    /// produces a countdown: the deadline is reconstructed from the ETA and the
    /// timestamp that were already in the file. Encoding stays synthesised.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        reading = try container.decode(BatteryReading.self, forKey: .reading)
        etaTo80 = try container.decodeIfPresent(TimeInterval.self, forKey: .etaTo80)
        timeToEmpty = try container.decodeIfPresent(TimeInterval.self, forKey: .timeToEmpty)
        chargingWatts = try container.decodeIfPresent(Double.self, forKey: .chargingWatts)
        lastSeen = try container.decode(Date.self, forKey: .lastSeen)
        isStale = try container.decodeIfPresent(Bool.self, forKey: .isStale) ?? false
        detailAge = try container.decodeIfPresent(TimeInterval.self, forKey: .detailAge)
        error = try container.decodeIfPresent(MonitorError.self, forKey: .error)
        etaTo80At = try container.decodeIfPresent(Date.self, forKey: .etaTo80At)
            ?? etaTo80.map { lastSeen.addingTimeInterval($0.rounded()) }
    }
}

/// What the menu-bar app reads: both devices, side by side.
public struct TandemSnapshot: Sendable, Codable, Equatable {
    public var generatedAt: Date
    public var mac: DeviceStatus?
    public var phone: DeviceStatus?
    /// The typed reason the last phone poll failed, or `nil` if it did not.
    /// Set even when `phone` still carries a retained older reading.
    public var phoneError: MonitorError?
    /// The typed reason the last Mac poll failed, or `nil`.
    public var macError: MonitorError?

    public init(
        generatedAt: Date = Date(),
        mac: DeviceStatus? = nil,
        phone: DeviceStatus? = nil,
        phoneError: MonitorError? = nil,
        macError: MonitorError? = nil
    ) {
        self.generatedAt = generatedAt
        self.mac = mac
        self.phone = phone
        self.phoneError = phoneError
        self.macError = macError
    }
}

/// Writes snapshots to disk as JSON, atomically.
///
/// The menu-bar app will point this at an App Group container so the extension
/// and the app read the same file.
public actor SnapshotStore {
    public nonisolated let url: URL

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init(url: URL) {
        self.url = url
    }

    /// Encode and replace the file in one step. `Data.write(.atomic)` renames a
    /// temp file into place, so a reader never sees a half-written snapshot.
    public func write(_ snapshot: TandemSnapshot) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic])
    }

    public func read() throws -> TandemSnapshot {
        let data = try Data(contentsOf: url)
        return try decoder.decode(TandemSnapshot.self, from: data)
    }

    public func encode(_ snapshot: TandemSnapshot) throws -> Data {
        try encoder.encode(snapshot)
    }
}
