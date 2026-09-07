import Foundation

/// The synthetic day the large widget shows in the gallery and before the app
/// has written a real `history-summary.json`.
///
/// Deliberately the *same two shapes* as the approved summary mock-ups
/// (`docs/design/summary/gen.py`, `series_mac` / `series_phone`): the Mac
/// drains from 62 % to 32 %, charges to 100 % and coasts back down; the phone
/// slides from 93 % to 29 % and is picked up onto a charger at the end, which
/// lands it on exactly the 64 % `SampleSnapshot` shows in the tile above.
///
/// The Mac's coast is the one number changed from the mock-up: gen.py's slope
/// ends the day at 90 %, and `SampleSnapshot`'s Mac reads 71 %. A gallery
/// preview whose tile and whose chart disagree about the same battery looks
/// like a bug, so the coast is steepened to land on 71 % instead. The shape —
/// discharge, fast charge, slow coast — is the mock-up's.
enum SampleHistory {

    /// 48 points, evenly spaced across the 24 h ending at `now` — the same
    /// count `gen.py` drew and half the 96 the real series can carry.
    static let pointCount = 48
    static let window: TimeInterval = 24 * 3600

    static func make(now: Date = Date()) -> HistorySummary {
        HistorySummary(
            generatedAt: now,
            devices: [
                device(
                    id: "sample-mac",
                    kind: .mac,
                    name: "MacBook Pro",
                    now: now,
                    percent: 90,
                    isCharging: false,
                    shape: macShape,
                    // The charge that took it from 32 % to 100 %, i.e. the
                    // rising stretch of `series_mac`.
                    session: (from: 0.25, to: 0.42, open: false)
                ),
                device(
                    id: "sample-iphone",
                    kind: .iphone,
                    name: "iPhone",
                    now: now,
                    percent: 64,
                    isCharging: true,
                    shape: phoneShape,
                    // Still on the charger at `now`, so the session is open.
                    session: (from: 0.82, to: 1.0, open: true)
                )
            ]
        )
    }

    /// `series_mac`: discharge, a fast charge, then a coast that ends on
    /// `SampleSnapshot`'s 71 %.
    private static func macShape(_ t: Double) -> (percent: Double, charging: Bool) {
        if t < 0.25 { return (62 - t * 120, false) }
        if t < 0.42 { return (32 + (t - 0.25) * 400, true) }
        return (100 - (t - 0.42) * 50, false)
    }

    /// `series_phone`: a long steady drain, then a charge at the end.
    private static func phoneShape(_ t: Double) -> (percent: Double, charging: Bool) {
        if t < 0.82 { return (93 - t * 78, false) }
        return (29 + (t - 0.82) * 195, true)
    }

    private static func device(
        id: String,
        kind: DeviceKind,
        name: String,
        now: Date,
        percent: Int,
        isCharging: Bool,
        shape: (Double) -> (percent: Double, charging: Bool),
        session: (from: Double, to: Double, open: Bool)
    ) -> DeviceHistory {
        let start = now.addingTimeInterval(-window)
        let series = (0..<pointCount).map { index -> SeriesPoint in
            let t = Double(index) / Double(pointCount - 1)
            let value = shape(t)
            return SeriesPoint(
                t: start.addingTimeInterval(t * window),
                percent: Int(max(0, min(100, value.percent)).rounded()),
                isCharging: value.charging
            )
        }
        let sessionStart = start.addingTimeInterval(session.from * window)
        let sessionEnd = start.addingTimeInterval(session.to * window)
        return DeviceHistory(
            device: id,
            kind: kind,
            name: name,
            lastSeen: now,
            percent: percent,
            isCharging: isCharging,
            lastSession: ChargeSession(
                device: id,
                start: sessionStart,
                end: session.open ? nil : sessionEnd,
                fromPercent: Int(max(0, min(100, shape(session.from).percent)).rounded()),
                toPercent: Int(max(0, min(100, shape(session.to).percent)).rounded())
            ),
            series: series
        )
    }
}
