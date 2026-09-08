import Foundation

/// The synthetic day both bigger families show in the gallery and before the
/// app has written a real `history-summary.json`.
///
/// It is the approved mock-up's day, column for column
/// (`docs/design/widget/gen.py`, `MAC["bars"]`/`["states"]` and `PHN`): the Mac
/// spends the night on the wall at 90 %, comes off it in the morning and drains
/// to 30 % before being plugged back in; the phone comes off its charger at
/// 92 % and slides to 38 %. The last column of each is what `SampleSnapshot`
/// shows in the tile above it, so the gallery preview is one coherent picture
/// rather than a tile and a chart disagreeing about the same battery.
///
/// Written as twelve two-hour columns rather than as a curve because that is
/// the resolution the design was approved at: `DayBars.fold` turns the 48 bins
/// below straight back into these twelve, exactly, with nothing left to round.
enum SampleHistory {

    /// Half-hour bins across the 24 h ending at `now` — the same 48
    /// `HistoryStore` writes.
    static let binCount = 48
    static let binWidth: TimeInterval = 30 * 60
    static let window: TimeInterval = Double(binCount) * binWidth

    /// Four half-hour bins to a mock-up column.
    private static let binsPerColumn = binCount / DayBars.count

    /// `MAC` in the mock-up: six columns on the wall, five on battery, then
    /// back on the charger.
    static let macDay: [TileBar] = day(
        [90, 90, 90, 90, 90, 90, 86, 74, 60, 44, 30, 32],
        "mmmmmmbbbbbc"
    )

    /// `PHN`: a charge that ends at 92 %, then a long steady drain.
    static let phoneDay: [TileBar] = day(
        [62, 78, 92, 86, 80, 74, 68, 60, 54, 48, 42, 38],
        "ccbbbbbbbbbb"
    )

    static var macPercent: Int { macDay.last?.percent ?? 0 }
    static var phonePercent: Int { phoneDay.last?.percent ?? 0 }

    static func make(now: Date = Date()) -> HistorySummary {
        HistorySummary(
            generatedAt: now,
            devices: [
                device(id: "sample-mac", kind: .mac, name: "MacBook Pro", columns: macDay, now: now),
                device(id: "sample-iphone", kind: .iphone, name: "iPhone", columns: phoneDay, now: now)
            ]
        )
    }

    // MARK: - Building

    /// `[90, 86, …]` + `"mmb…"` → twelve columns. The state letters are the
    /// mock-up's own: `b`attery, `c`harging, `m`ains.
    private static func day(_ percents: [Int], _ states: String) -> [TileBar] {
        zip(percents, states).map { percent, letter in
            TileBar(percent: percent, state: state(letter))
        }
    }

    private static func state(_ letter: Character) -> HistoryBinState {
        switch letter {
        case "c": .charging
        case "m": .mains
        default: .battery
        }
    }

    /// Twelve columns → 48 bins, oldest first, the last ending at `now`.
    ///
    /// The level ramps across each column's four bins so the large family's
    /// plot is a curve rather than a staircase, and lands *exactly* on the
    /// column's figure in its last bin — which is the one `DayBars.fold` reads
    /// back, so the strip is the mock-up's twelve numbers and nothing else.
    private static func bins(_ columns: [TileBar], now: Date) -> [HistoryBin] {
        let first = now.addingTimeInterval(-Double(binCount - 1) * binWidth)
        return (0..<binCount).map { index in
            let column = index / binsPerColumn
            let step = index % binsPerColumn
            let target = columns[column].percent ?? 0
            let previous = column > 0 ? (columns[column - 1].percent ?? target) : target
            let fraction = Double(step + 1) / Double(binsPerColumn)
            let state = columns[column].state
            return HistoryBin(
                start: first.addingTimeInterval(Double(index) * binWidth),
                percent: Int((Double(previous) + (Double(target) - Double(previous)) * fraction).rounded()),
                state: state,
                // Only a device on the wall reports what the wall is giving it.
                powerInW: state == .charging ? 136 : (state == .mains ? 13 : nil),
                systemLoadW: 24
            )
        }
    }

    private static func device(
        id: String,
        kind: DeviceKind,
        name: String,
        columns: [TileBar],
        now: Date
    ) -> DeviceHistory {
        let bins = bins(columns, now: now)
        return DeviceHistory(
            device: id,
            kind: kind,
            name: name,
            lastSeen: now,
            percent: columns.last?.percent,
            isCharging: columns.last?.state == .charging,
            lastSession: session(device: id, bins: bins, now: now),
            series: bins.map {
                SeriesPoint(
                    t: min(now, $0.start.addingTimeInterval(binWidth / 2)),
                    percent: $0.percent ?? 0,
                    isCharging: $0.state == .charging
                )
            },
            bins24h: bins
        )
    }

    /// The newest run of charging bins, open when it runs to the end of the
    /// window — which is the difference between the Mac's line ("→ now") and
    /// the phone's ("→ 04:31") on the large widget.
    private static func session(device: String, bins: [HistoryBin], now: Date) -> ChargeSession? {
        guard let end = bins.lastIndex(where: { $0.state == .charging }) else { return nil }
        var start = end
        while start > 0, bins[start - 1].state == .charging { start -= 1 }
        return ChargeSession(
            device: device,
            start: bins[start].start,
            end: end == bins.count - 1 ? nil : bins[end].start.addingTimeInterval(binWidth),
            fromPercent: bins[start].percent ?? 0,
            toPercent: bins[end].percent ?? 0
        )
    }
}
