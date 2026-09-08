import Foundation

// MARK: - One stored row

/// A single row of `readings`: one sample of one device at one instant.
///
/// Every detail field is optional and `nil` means **unknown**, never zero — the
/// same rule NOTES.md §13.2 imposes on a partial `BatteryReading`. A row derived
/// from a degraded-tier reading carries `percent`, `isCharging`,
/// `externalConnected` and `fullyCharged` and nothing else.
public struct HistoryReading: Sendable, Codable, Equatable {
    public var timestamp: Date
    /// `BatteryReading.deviceID` — the Mac's hardware id or the phone's UDID.
    public var device: String
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    /// Wall power while charging, otherwise signed battery power (`-` = draw).
    public var watts: Double?
    public var adapterWatts: Int?
    public var rawCurrentMAh: Int?
    public var rawMaxMAh: Int?
    public var designMAh: Int?
    public var cycleCount: Int?
    public var temperatureC: Double?
    /// What the machine itself was drawing at this instant
    /// (`BatteryReading.systemLoadW`, `PowerTelemetryData.SystemLoad`),
    /// unsigned. `nil` on a device that reports no telemetry — an iPhone on
    /// battery, or any partial reading. Schema v4.
    ///
    /// Deliberately **not** part of `isMateriallySame`: system load moves by a
    /// watt or two every second on an idle Mac, and letting it break the skip
    /// rule would turn a quiet week's ~860 rows back into ~10 000.
    public var systemLoadW: Double?
    /// What the wall was putting into the machine at this instant
    /// (`BatteryReading.systemPowerInW`, `PowerTelemetryData.SystemPowerIn`),
    /// unsigned. Present whenever the device is **plugged in — charging or
    /// not** — which is exactly what makes it the honest input for the power
    /// chart: a Mac held at 90 % on a 140 W brick draws 13 W from the wall and
    /// charges at nothing at all. `nil` on battery and on any device that
    /// reports no telemetry. Schema v5.
    ///
    /// Like `systemLoadW`, deliberately **not** part of `isMateriallySame`:
    /// it moves by a watt every few seconds and would defeat the skip rule.
    public var powerInW: Double?
    public var isPartial: Bool
    public var transport: Transport

    public init(
        timestamp: Date,
        device: String,
        percent: Int,
        isCharging: Bool,
        externalConnected: Bool,
        fullyCharged: Bool,
        watts: Double? = nil,
        adapterWatts: Int? = nil,
        rawCurrentMAh: Int? = nil,
        rawMaxMAh: Int? = nil,
        designMAh: Int? = nil,
        cycleCount: Int? = nil,
        temperatureC: Double? = nil,
        isPartial: Bool = false,
        transport: Transport = .local,
        systemLoadW: Double? = nil,
        powerInW: Double? = nil
    ) {
        self.timestamp = timestamp
        self.device = device
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.watts = watts
        self.adapterWatts = adapterWatts
        self.rawCurrentMAh = rawCurrentMAh
        self.rawMaxMAh = rawMaxMAh
        self.designMAh = designMAh
        self.cycleCount = cycleCount
        self.temperatureC = temperatureC
        self.isPartial = isPartial
        self.transport = transport
        self.systemLoadW = systemLoadW
        self.powerInW = powerInW
    }
}

extension HistoryReading {

    /// Project a `DeviceStatus` onto a row.
    ///
    /// * `watts` prefers the estimator's wall figure while charging and falls
    ///   back to the signed battery power. A partial reading with no full read
    ///   behind it reports `0` W meaning *unknown*, so that becomes `nil`
    ///   (the same test `StatusFormatter.isUnknownPower` makes).
    /// * Every other detail is stored only when it is non-zero, which is exactly
    ///   the "0 means unknown" rule for a partial reading and is harmless for a
    ///   full one (no real battery reports a 0 mAh design capacity).
    public init(status: DeviceStatus) {
        let reading = status.reading
        let watts: Double?
        if let charging = status.chargingWatts {
            watts = charging
        } else if reading.isPartial && reading.batteryPowerW == 0 {
            watts = nil
        } else {
            watts = reading.batteryPowerW
        }
        self.init(
            timestamp: reading.timestamp,
            device: reading.deviceID,
            percent: reading.percent,
            isCharging: reading.isCharging,
            externalConnected: reading.externalConnected,
            fullyCharged: reading.fullyCharged,
            watts: watts,
            adapterWatts: reading.adapterWatts.flatMap { $0 > 0 ? $0 : nil },
            rawCurrentMAh: reading.rawCurrentMAh > 0 ? reading.rawCurrentMAh : nil,
            rawMaxMAh: reading.rawMaxMAh > 0 ? reading.rawMaxMAh : nil,
            designMAh: reading.designMAh > 0 ? reading.designMAh : nil,
            cycleCount: reading.cycleCount > 0 ? reading.cycleCount : nil,
            temperatureC: reading.temperatureC != 0 ? reading.temperatureC : nil,
            isPartial: reading.isPartial,
            transport: reading.transport,
            // Already `nil` when the device reports no telemetry, so it needs
            // no "0 means unknown" rescue of its own.
            systemLoadW: reading.systemLoadW,
            // Ditto: the parser turns `SystemPowerIn == 0` — which is what a
            // device on battery reports — into `nil` before we ever see it.
            powerInW: reading.systemPowerInW
        )
    }

    /// The skip rule (NOTES.md §15): two rows are "materially the same" when
    /// percent, the three plug flags and the wattage all agree, watts to within
    /// `wattTolerance`. A row that is materially the same as its predecessor is
    /// only written once `HistoryStore.idleInterval` has passed.
    public func isMateriallySame(as other: HistoryReading, wattTolerance: Double = 0.5) -> Bool {
        guard percent == other.percent,
              isCharging == other.isCharging,
              externalConnected == other.externalConnected,
              fullyCharged == other.fullyCharged
        else { return false }
        switch (watts, other.watts) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return abs(lhs - rhs) <= wattTolerance
        default: return false
        }
    }
}

// MARK: - Derived: a charge session

/// One stretch of the device being on external power.
///
/// Starts when `externalConnected` goes true, ends at the last reading that
/// still showed external power — either because the next reading showed it
/// gone, or because the next reading is more than
/// `ChargeSessionBuilder.maximumGap` later and we simply have no idea what
/// happened in between. `end == nil` means the session is still open: the newest
/// reading we have is still on the charger.
public struct ChargeSession: Sendable, Codable, Equatable {
    public var device: String
    public var start: Date
    public var end: Date?
    public var fromPercent: Int
    public var toPercent: Int
    /// Highest positive wattage seen in the session. `nil` when no sample
    /// carried a wattage (every reading was partial, say).
    public var peakWatts: Double?
    /// Arithmetic mean of the positive wattage samples — not time-weighted; use
    /// `energyWh` when you want the integral.
    public var averageWatts: Double?
    /// The largest adapter rating reported during the session.
    public var adapterWatts: Int?
    /// First reading at or after `start` that read 80 % or more.
    public var reached80At: Date?
    /// `Σ watts · Δt`, with each gap clipped to `ChargeSessionBuilder.maximumGap`
    /// so a laptop that slept for six hours does not book six hours of charging.
    public var energyWh: Double?

    public init(
        device: String,
        start: Date,
        end: Date? = nil,
        fromPercent: Int,
        toPercent: Int,
        peakWatts: Double? = nil,
        averageWatts: Double? = nil,
        adapterWatts: Int? = nil,
        reached80At: Date? = nil,
        energyWh: Double? = nil
    ) {
        self.device = device
        self.start = start
        self.end = end
        self.fromPercent = fromPercent
        self.toPercent = toPercent
        self.peakWatts = peakWatts
        self.averageWatts = averageWatts
        self.adapterWatts = adapterWatts
        self.reached80At = reached80At
        self.energyWh = energyWh
    }

    /// True while the newest reading in the window is still on the charger.
    public var isOpen: Bool { end == nil }
    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
    public var percentGained: Int { max(0, toPercent - fromPercent) }
    /// Seconds from `start` to 80 %, when it got there inside this session.
    public var timeTo80: TimeInterval? { reached80At.map { $0.timeIntervalSince(start) } }
}

// MARK: - Derived: one day

/// A day's worth of battery behaviour for one device.
///
/// `day` is midnight at the start of the day in the calendar the stats were
/// computed with (the store uses `Calendar.current`).
public struct DailyStat: Sendable, Codable, Equatable {
    public var device: String
    public var day: Date
    public var minPercent: Int
    public var maxPercent: Int
    /// Sum of the downward percent steps — how much battery the day actually ate.
    public var percentConsumed: Int
    /// Sum of the upward percent steps.
    public var percentGained: Int
    /// `percentGained / 100`. A charge from 20 % to 100 % is 0.8 cycles. This is
    /// an *estimate* from our own samples, not the gauge's `cycleCount`.
    public var cyclesEstimate: Double
    public var minutesOnCharger: Double
    /// Mean magnitude of the negative wattage samples, i.e. average draw while
    /// running on the battery. `nil` when nothing was measured.
    public var averageDrawWatts: Double?
    /// **Always `nil`.** Neither OS tells us screen-on time over the wire and we
    /// are not going to invent it; the field exists so the UI can render
    /// "unknown" rather than nothing at all.
    public var screenOnMinutes: Double?
    public var sampleCount: Int

    public init(
        device: String,
        day: Date,
        minPercent: Int,
        maxPercent: Int,
        percentConsumed: Int,
        percentGained: Int,
        cyclesEstimate: Double,
        minutesOnCharger: Double,
        averageDrawWatts: Double? = nil,
        screenOnMinutes: Double? = nil,
        sampleCount: Int
    ) {
        self.device = device
        self.day = day
        self.minPercent = minPercent
        self.maxPercent = maxPercent
        self.percentConsumed = percentConsumed
        self.percentGained = percentGained
        self.cyclesEstimate = cyclesEstimate
        self.minutesOnCharger = minutesOnCharger
        self.averageDrawWatts = averageDrawWatts
        self.screenOnMinutes = screenOnMinutes
        self.sampleCount = sampleCount
    }
}

// MARK: - The summary the UI reads

/// Battery health as the gauge reports it.
///
/// `percent` is `rawMax / design` **capped at 100**, because a fresh pack often
/// gauges above its design figure and "103 % healthy" reads as a bug. The raw
/// numbers are kept alongside so a detail view can show them uncapped.
public struct BatteryHealth: Sendable, Codable, Equatable {
    public var rawMaxMAh: Int
    /// `DesignCapacity`, or `NominalChargeCapacity` when the device reports only
    /// that (see `BatteryPlistParser`). Both fixtures' iPhones use the latter.
    public var designMAh: Int
    public var percent: Int
    public var fraction: Double

    public init(rawMaxMAh: Int, designMAh: Int) {
        self.rawMaxMAh = rawMaxMAh
        self.designMAh = designMAh
        let fraction = designMAh > 0 ? Double(rawMaxMAh) / Double(designMAh) : 0
        self.fraction = fraction
        self.percent = min(100, Int((fraction * 100).rounded()))
    }
}

/// One point of the 24 h chart.
public struct SeriesPoint: Sendable, Codable, Equatable {
    public var t: Date
    public var percent: Int
    public var isCharging: Bool

    public init(t: Date, percent: Int, isCharging: Bool) {
        self.t = t
        self.percent = percent
        self.isCharging = isCharging
    }
}

/// What the device was doing for most of one bin of the 24 h chart.
///
/// Three states, not two, because "plugged in" and "charging" are different
/// answers and the chart is the one place that difference is visible: a Mac
/// held at 90 % on a 140 W brick is on `mains`, taking its power from the wall
/// and putting none of it into the pack. An iPhone never reports `mains` — it
/// either charges or it does not — and the code path is the same either way.
public enum HistoryBinState: String, Sendable, Codable, CaseIterable {
    /// `external == false`: running off the pack.
    case battery
    /// `external && isCharging`.
    case charging
    /// `external && !isCharging`: on the wall, holding.
    case mains
    /// **Nobody was watching.** No reading fell in the bin and the last one is
    /// too old to speak for it (`ChargeSessionBuilder.carryWindow`), so the
    /// level is unknown too: `percent`, `powerInW` and `systemLoadW` are all
    /// `nil` beside it. Drawn as a stub at the baseline, never as a bar and
    /// never as 0 %.
    ///
    /// Also what a state string this build has never heard of decodes to — a
    /// newer build's invention is, from here, exactly "we do not know".
    case unknown
}

/// One half-hour bin of the summary window's 24 h chart.
///
/// Unlike `SeriesPoint` — which is a *reading*, at whatever uneven instant the
/// skip rule happened to record one — a bin is a fixed slot on the clock, so
/// bars are the same width and a gap in the data is visible as a gap rather
/// than as a long straight line. `DeviceHistory.bins24h` holds 48 of them,
/// oldest first, the last one ending at `now`.
///
/// Every value is optional-shaped the way the rest of the store is: `nil` means
/// **unknown**, never zero (NOTES.md §15.1). A bin with no readings in it
/// carries the percent *and the state* forward from the bin before — a battery
/// that was at 90 % on the wall half an hour ago and has not been heard from
/// since is still at about 90 %, still on the wall — but only while the silence
/// is short (`ChargeSessionBuilder.carryWindow`, an hour). Past that the bin is
/// `.unknown` with no percent at all: the Mac's display sleeping stops the
/// phone being polled for hours at a time, and carrying the last figure across
/// that invented a flat shelf of level nobody ever measured. Either way the bin
/// reports no power, because nobody measured any.
public struct HistoryBin: Sendable, Codable, Equatable {
    /// The bin's left edge: a whole or half hour.
    public var start: Date
    /// The last reading in the bin, else the previous bin's figure carried
    /// forward, else `nil` — nothing has been recorded yet.
    public var percent: Int?
    /// The state most of the bin's readings were in, weighted by time; for a
    /// silent bin inside the carry window, the previous bin's state carried
    /// forward (a Mac asleep on its charger is still on `.mains` a quarter of
    /// an hour later), and `.unknown` for every longer silence.
    public var state: HistoryBinState
    /// True when a reading actually fell inside this bin. False for a bin that
    /// carried its neighbour's figure forward and for an `.unknown` one — the
    /// flag a view needs to tell "measured" from "inferred" without re-deriving
    /// the rule.
    public var isObserved: Bool
    /// Mean `HistoryReading.powerInW` over the bin's readings; `nil` when none
    /// of them carried one (every device on battery, every partial reading).
    public var powerInW: Double?
    /// Mean `HistoryReading.systemLoadW` over the bin's readings.
    public var systemLoadW: Double?

    public init(
        start: Date,
        percent: Int? = nil,
        state: HistoryBinState = .battery,
        powerInW: Double? = nil,
        systemLoadW: Double? = nil,
        isObserved: Bool = false
    ) {
        self.start = start
        self.percent = percent
        self.state = state
        self.powerInW = powerInW
        self.systemLoadW = systemLoadW
        self.isObserved = isObserved
    }

    /// Lenient on purpose, like `DeviceHistory`: this type crosses a file
    /// written by one process and read by another (NOTES.md §15.4), so a key
    /// that is missing — or a `state` a newer build wrote and this one has
    /// never heard of — has to decode to something sensible rather than throw
    /// the whole summary away.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.start = try container.decode(Date.self, forKey: .start)
        self.percent = try container.decodeIfPresent(Int.self, forKey: .percent)
        // A state string this build does not know is `.unknown`, not
        // `.battery`: guessing "on the pack" about a newer build's invention is
        // the very thing this type stopped doing. A file with no `state` key at
        // all predates the field entirely and keeps the old default.
        let name = (try? container.decodeIfPresent(String.self, forKey: .state)) ?? nil
        self.state = name.map { HistoryBinState(rawValue: $0) ?? .unknown } ?? .battery
        self.powerInW = try container.decodeIfPresent(Double.self, forKey: .powerInW)
        self.systemLoadW = try container.decodeIfPresent(Double.self, forKey: .systemLoadW)
        // Absent in every file written before the flag existed; `false` there
        // says "this build cannot tell", which is the truth about an old file.
        self.isObserved = ((try? container.decodeIfPresent(Bool.self, forKey: .isObserved)) ?? nil) ?? false
    }
}

/// Everything the summary view and the large widget need about one device.
public struct DeviceHistory: Sendable, Codable, Equatable {
    public var device: String
    public var kind: DeviceKind?
    public var name: String?
    public var lastSeen: Date?
    public var health: BatteryHealth?
    public var cycleCount: Int?
    public var temperatureC: Double?
    public var percent: Int?
    public var isCharging: Bool?
    /// The newest session, open or closed.
    public var lastSession: ChargeSession?
    public var today: DailyStat?
    /// Today first, then backwards; at most seven entries.
    public var week: [DailyStat]
    /// The last 24 h, downsampled to at most
    /// `HistoryStore.seriesPointLimit` (96) points.
    public var series: [SeriesPoint]
    /// The last 24 h as 48 half-hour bins, oldest first, the last one ending at
    /// `now` — what the summary window's chart draws (`HistoryStore.binCount`).
    ///
    /// `series` stays beside it, untouched, because the widget reads the same
    /// file and draws the line it has always drawn.
    public var bins24h: [HistoryBin]
    /// The last `HistoryStore.systemLoadSeriesLimit` (12) recorded values of
    /// `HistoryReading.systemLoadW`, oldest first — the summary window's
    /// sparkline beside the "System" row.
    ///
    /// Only readings that actually carried a figure are in it, so it is empty
    /// rather than zero-padded for a device that has never reported telemetry,
    /// and it is not a time series: the points are consecutive *readings*, which
    /// the skip rule makes deliberately uneven. A sparkline with no axis is the
    /// only honest thing to draw from that.
    public var systemLoadSeries: [Double]

    public init(
        device: String,
        kind: DeviceKind? = nil,
        name: String? = nil,
        lastSeen: Date? = nil,
        health: BatteryHealth? = nil,
        cycleCount: Int? = nil,
        temperatureC: Double? = nil,
        percent: Int? = nil,
        isCharging: Bool? = nil,
        lastSession: ChargeSession? = nil,
        today: DailyStat? = nil,
        week: [DailyStat] = [],
        series: [SeriesPoint] = [],
        systemLoadSeries: [Double] = [],
        bins24h: [HistoryBin] = []
    ) {
        self.device = device
        self.kind = kind
        self.name = name
        self.lastSeen = lastSeen
        self.health = health
        self.cycleCount = cycleCount
        self.temperatureC = temperatureC
        self.percent = percent
        self.isCharging = isCharging
        self.lastSession = lastSession
        self.today = today
        self.week = week
        self.series = series
        self.systemLoadSeries = systemLoadSeries
        self.bins24h = bins24h
    }

    /// Hand-written so a `history-summary.json` produced before `systemLoadSeries`
    /// existed still decodes: the synthesised `init(from:)` would demand the new
    /// key outright, and this file is written to disk and read back by another
    /// process (NOTES.md §15.4). Encoding stays synthesised.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.device = try container.decode(String.self, forKey: .device)
        self.kind = try container.decodeIfPresent(DeviceKind.self, forKey: .kind)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.lastSeen = try container.decodeIfPresent(Date.self, forKey: .lastSeen)
        self.health = try container.decodeIfPresent(BatteryHealth.self, forKey: .health)
        self.cycleCount = try container.decodeIfPresent(Int.self, forKey: .cycleCount)
        self.temperatureC = try container.decodeIfPresent(Double.self, forKey: .temperatureC)
        self.percent = try container.decodeIfPresent(Int.self, forKey: .percent)
        self.isCharging = try container.decodeIfPresent(Bool.self, forKey: .isCharging)
        self.lastSession = try container.decodeIfPresent(ChargeSession.self, forKey: .lastSession)
        self.today = try container.decodeIfPresent(DailyStat.self, forKey: .today)
        self.week = try container.decodeIfPresent([DailyStat].self, forKey: .week) ?? []
        self.series = try container.decodeIfPresent([SeriesPoint].self, forKey: .series) ?? []
        self.systemLoadSeries = try container.decodeIfPresent([Double].self, forKey: .systemLoadSeries) ?? []
        self.bins24h = try container.decodeIfPresent([HistoryBin].self, forKey: .bins24h) ?? []
    }
}

/// The file the app drops next to `snapshot.json` for the widget to read.
public struct HistorySummary: Sendable, Codable, Equatable {
    public var generatedAt: Date
    /// Mac first, then phone, then anything else — the order the UI stacks them.
    public var devices: [DeviceHistory]

    public init(generatedAt: Date = Date(), devices: [DeviceHistory] = []) {
        self.generatedAt = generatedAt
        self.devices = devices
    }

    public func device(_ id: String) -> DeviceHistory? {
        devices.first { $0.device == id }
    }

    public func device(kind: DeviceKind) -> DeviceHistory? {
        devices.first { $0.kind == kind }
    }
}

/// What `devices` remembers about a device id, so `--device iphone` resolves and
/// the summary can carry a name without re-reading a snapshot.
public struct HistoryDevice: Sendable, Codable, Equatable {
    public var id: String
    public var kind: DeviceKind
    public var name: String
    public var lastSeen: Date

    public init(id: String, kind: DeviceKind, name: String, lastSeen: Date) {
        self.id = id
        self.kind = kind
        self.name = name
        self.lastSeen = lastSeen
    }
}

// MARK: - Sleep and wake

/// A "the machine went away" / "the machine came back" marker.
///
/// The store has no other way to tell a Mac that slept on the charger from a
/// Mac that was unplugged and carried off: both look like a hole in `readings`
/// (NOTES.md §15.7). The app records one of these from
/// `NSWorkspace.willSleepNotification` / `didWakeNotification`, and
/// `ChargeSessionBuilder` then treats a gap bracketed by a sleep *and* a wake
/// as one continuous session rather than as two.
public struct SleepMarker: Sendable, Codable, Equatable {

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case sleep
        case wake
    }

    public var timestamp: Date
    public var kind: Kind

    public init(timestamp: Date, kind: Kind) {
        self.timestamp = timestamp
        self.kind = kind
    }
}

// MARK: - Capacity over time

/// How the gauge's full-charge capacity has moved across the retained history.
///
/// `rawMaxMAh` from the oldest and the newest **full** reading, plus the span
/// between them, so a UI can say "−12 mAh over 21 days" — or, when the span is
/// too short to mean anything, say nothing at all. There is deliberately no
/// smoothing and no projection: two measurements and the time between them.
public struct CapacityTrend: Sendable, Codable, Equatable {
    public var firstMAh: Int
    public var lastMAh: Int
    public var first: Date
    public var last: Date

    public init(firstMAh: Int, lastMAh: Int, first: Date, last: Date) {
        self.firstMAh = firstMAh
        self.lastMAh = lastMAh
        self.first = first
        self.last = last
    }

    public var deltaMAh: Int { lastMAh - firstMAh }
    public var span: TimeInterval { last.timeIntervalSince(first) }
    public var days: Int { Int((span / 86_400).rounded()) }
}
