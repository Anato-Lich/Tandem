import Foundation

/// Everything derived from a run of `HistoryReading`s, with no database, no
/// clock and no I/O anywhere in it — so all of it is unit-testable against
/// synthetic rows.
///
/// The three products are charge sessions (`sessions(from:device:)`), per-day
/// statistics (`dailyStats(from:device:)`) and the downsampled chart series
/// (`downsample(_:limit:)`).
public enum ChargeSessionBuilder {

    /// A hole in the data longer than this ends whatever was going on. The
    /// laptop slept, the phone went off the air (NOTES.md §5), the app was not
    /// running — either way we know nothing about the interval and refuse to
    /// pretend otherwise.
    public static let maximumGap: TimeInterval = 30 * 60

    /// The percent a session is considered to have "reached" for `reached80At`.
    public static let fastChargeThreshold = 80

    // MARK: - Charge sessions

    /// Split a device's readings into charge sessions.
    ///
    /// * A session **starts** at the first reading whose `externalConnected` is
    ///   true after one where it was not (or at the first reading in the window,
    ///   if that one is already on the charger — the start is then clipped by
    ///   the window rather than observed).
    /// * It **ends** at the last reading that still showed external power. The
    ///   trigger is either a reading with `externalConnected == false`, or a gap
    ///   longer than `maximumGap`.
    /// * The last session has `end == nil` when the newest reading is still on
    ///   the charger: it is still running.
    ///
    /// `readings` may be in any order; they are sorted here. Readings for other
    /// devices are ignored when `device` is given.
    ///
    /// **Sleep** (`markers`, NOTES.md §15.7): a gap longer than `maximumGap`
    /// normally ends the session, because we know nothing about the interval.
    /// When the app has recorded a `.sleep` and a matching `.wake` inside that
    /// gap, and the readings on both sides of it were on external power, we do
    /// know: the machine slept on the charger, and the gap is *not* a break. The
    /// session then continues across it, and the slept-through interval
    /// contributes no energy — a sleeping Mac's last measured wattage says
    /// nothing about the hours that followed.
    public static func sessions(
        from readings: [HistoryReading],
        device: String? = nil,
        markers: [SleepMarker] = []
    ) -> [ChargeSession] {
        let rows = readings
            .filter { device == nil || $0.device == device }
            .sorted { $0.timestamp < $1.timestamp }
        guard !rows.isEmpty else { return [] }

        let sleeps = markers.sorted { $0.timestamp < $1.timestamp }

        var sessions: [ChargeSession] = []
        var accumulator: Accumulator?
        var previous: HistoryReading?

        for row in rows {
            if let previous, row.timestamp.timeIntervalSince(previous.timestamp) > maximumGap {
                if previous.externalConnected, row.externalConnected,
                   isSleepGap(from: previous.timestamp, to: row.timestamp, markers: sleeps) {
                    // Slept on the charger: one session, and no energy booked
                    // for the interval nobody measured.
                    accumulator?.skipNextInterval = true
                } else if var open = accumulator {
                    sessions.append(open.finish(closed: true))
                    accumulator = nil
                }
            }
            if row.externalConnected {
                if accumulator == nil {
                    accumulator = Accumulator(first: row)
                } else {
                    accumulator?.add(row)
                }
            } else if var open = accumulator {
                sessions.append(open.finish(closed: true))
                accumulator = nil
            }
            previous = row
        }
        if var open = accumulator {
            // Still on the charger as of the newest reading we hold.
            sessions.append(open.finish(closed: false))
        }
        return sessions
    }

    /// Is the hole between two readings one the app told us about?
    ///
    /// True when a `.sleep` marker falls inside `[from, to]` and a `.wake`
    /// marker falls at or after it and no later than `to` — i.e. the machine
    /// went away and came back inside the gap. A sleep with no wake yet (still
    /// asleep, or the wake was never recorded) is *not* a bracket: the gap
    /// stays a gap.
    static func isSleepGap(from: Date, to: Date, markers: [SleepMarker]) -> Bool {
        guard let sleep = markers.first(where: {
            $0.kind == .sleep && $0.timestamp >= from && $0.timestamp <= to
        }) else { return false }
        return markers.contains {
            $0.kind == .wake && $0.timestamp >= sleep.timestamp && $0.timestamp <= to
        }
    }

    /// Accumulates one session as the walk goes.
    private struct Accumulator {
        let device: String
        let start: Date
        let fromPercent: Int
        var last: HistoryReading
        var peakWatts: Double?
        var wattSum: Double = 0
        var wattCount = 0
        var adapterWatts: Int?
        var reached80At: Date?
        var energyWh: Double = 0
        var sawEnergy = false
        /// Set when the interval about to close was slept through: it gets no
        /// energy, because the wattage measured before the machine slept says
        /// nothing about the hours after it did.
        var skipNextInterval = false

        init(first: HistoryReading) {
            device = first.device
            start = first.timestamp
            fromPercent = first.percent
            last = first
            note(first)
        }

        mutating func note(_ row: HistoryReading) {
            if let watts = row.watts, watts > 0 {
                peakWatts = max(peakWatts ?? watts, watts)
                wattSum += watts
                wattCount += 1
            }
            if let adapter = row.adapterWatts {
                adapterWatts = max(adapterWatts ?? adapter, adapter)
            }
            if reached80At == nil, row.percent >= fastChargeThreshold {
                reached80At = row.timestamp
            }
        }

        mutating func add(_ row: HistoryReading) {
            // Integrate the interval that just closed, using the wattage measured
            // at its start and clipping the gap so a sleep is not counted.
            let gap = skipNextInterval ? 0 : min(row.timestamp.timeIntervalSince(last.timestamp), maximumGap)
            skipNextInterval = false
            if gap > 0, let watts = last.watts, watts > 0 {
                energyWh += watts * gap / 3600
                sawEnergy = true
            }
            last = row
            note(row)
        }

        mutating func finish(closed: Bool) -> ChargeSession {
            ChargeSession(
                device: device,
                start: start,
                end: closed ? last.timestamp : nil,
                fromPercent: fromPercent,
                toPercent: last.percent,
                peakWatts: peakWatts,
                averageWatts: wattCount > 0 ? wattSum / Double(wattCount) : nil,
                adapterWatts: adapterWatts,
                reached80At: reached80At,
                energyWh: sawEnergy ? energyWh : nil
            )
        }
    }

    // MARK: - Daily statistics

    /// Per-day statistics, newest day first.
    ///
    /// * `percentConsumed` / `percentGained` are the sums of the downward and
    ///   upward percent steps between consecutive readings **inside one day**;
    ///   a step across midnight belongs to neither day.
    /// * `minutesOnCharger` sums the intervals whose *earlier* reading was on
    ///   external power, each interval clipped to `maximumGap`.
    /// * `averageDrawWatts` is the mean magnitude of the negative wattage
    ///   samples — the power actually coming out of the battery, whether or not
    ///   a charger was attached (a Mac under load can discharge while plugged).
    /// * `screenOnMinutes` is always `nil`. See `DailyStat`.
    public static func dailyStats(
        from readings: [HistoryReading],
        device: String? = nil,
        calendar: Calendar = .current
    ) -> [DailyStat] {
        let rows = readings
            .filter { device == nil || $0.device == device }
            .sorted { $0.timestamp < $1.timestamp }
        guard !rows.isEmpty else { return [] }

        var byDay: [Date: [HistoryReading]] = [:]
        for row in rows {
            byDay[calendar.startOfDay(for: row.timestamp), default: []].append(row)
        }

        return byDay.map { day, dayRows in
            var consumed = 0
            var gained = 0
            var chargerSeconds: TimeInterval = 0
            var drawSum: Double = 0
            var drawCount = 0

            for (index, row) in dayRows.enumerated() {
                if let watts = row.watts, watts < 0 {
                    drawSum += -watts
                    drawCount += 1
                }
                guard index > 0 else { continue }
                let previous = dayRows[index - 1]
                let delta = row.percent - previous.percent
                if delta > 0 { gained += delta } else { consumed += -delta }
                if previous.externalConnected {
                    chargerSeconds += min(row.timestamp.timeIntervalSince(previous.timestamp), maximumGap)
                }
            }

            return DailyStat(
                device: dayRows[0].device,
                day: day,
                minPercent: dayRows.map(\.percent).min() ?? 0,
                maxPercent: dayRows.map(\.percent).max() ?? 0,
                percentConsumed: consumed,
                percentGained: gained,
                cyclesEstimate: Double(gained) / 100,
                minutesOnCharger: chargerSeconds / 60,
                averageDrawWatts: drawCount > 0 ? drawSum / Double(drawCount) : nil,
                screenOnMinutes: nil,
                sampleCount: dayRows.count
            )
        }
        .sorted { $0.day > $1.day }
    }

    // MARK: - The chart series

    /// Reduce a run of readings to at most `limit` points by keeping the last
    /// reading of each of `limit` equal time buckets spanning
    /// `[from, through]`.
    ///
    /// Bucketing rather than "every n-th row" keeps the x-axis linear in time,
    /// which matters because the skip rule (NOTES.md §15) makes the rows
    /// deliberately uneven: an idle night is one row per ten minutes and a
    /// charge is one row per poll.
    public static func downsample(
        _ readings: [HistoryReading],
        from: Date,
        through: Date,
        limit: Int
    ) -> [SeriesPoint] {
        let rows = readings.sorted { $0.timestamp < $1.timestamp }
        guard limit > 0, !rows.isEmpty else { return [] }
        let span = through.timeIntervalSince(from)
        guard span > 0 else {
            return rows.suffix(1).map { SeriesPoint(t: $0.timestamp, percent: $0.percent, isCharging: $0.isCharging) }
        }
        let bucketWidth = span / Double(limit)

        var lastByBucket: [Int: HistoryReading] = [:]
        for row in rows {
            let offset = row.timestamp.timeIntervalSince(from)
            guard offset >= 0 else { continue }
            let bucket = min(limit - 1, Int(offset / bucketWidth))
            lastByBucket[bucket] = row
        }
        return lastByBucket.keys.sorted().compactMap { bucket in
            lastByBucket[bucket].map {
                SeriesPoint(t: $0.timestamp, percent: $0.percent, isCharging: $0.isCharging)
            }
        }
    }
}
