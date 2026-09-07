import Charts
import SwiftUI

/// The two colours the chart uses to tell one device from the other — the same
/// pair the summary window's palette calls `green` and `blue`.
///
/// This is the one place in the widget where colour does **not** mean level.
/// Two lines in one plot have to be told apart somehow, and the alternative
/// (dashing one of them) is worse at this size; the tiles above still colour
/// their rings strictly by level, and the legend names which line is which so
/// nobody has to guess.
enum ChartPalette {
    static let mac = Color(rgb: 0x30D158)
    static let phone = Color(rgb: 0x64D2FF)

    /// A charging stretch, shaded behind that device's own line.
    static let spanAlpha: Double = 0.12
}

extension HistorySummary {

    /// Older than this and the summary is treated as absent: it is no longer a
    /// picture of the last 24 h, it is a picture of some earlier day with a
    /// "now" marker lying about where the present is. The app rewrites the file
    /// at most every ten minutes while it runs, so two hours means the app has
    /// been gone for a while.
    static let freshnessWindow: TimeInterval = 2 * 3600

    func isFresh(now: Date, within window: TimeInterval = HistorySummary.freshnessWindow) -> Bool {
        now.timeIntervalSince(generatedAt) < window
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: 1
        )
    }
}

/// `systemLarge`: the medium widget's two tiles, then the day both devices had.
///
/// ```
///  ╭────────────────────────────────╮
///  │ ( ▭ ) −13 W │ ( ▮ ) 36/45 W    │  the medium tiles, verbatim
///  │ 90 %   4:19 │ 64 %  80 % · 14  │
///  ├────────────────────────────────┤
///  │ 24 HOURS          ● Mac ● iPh  │  one card, both devices
///  │ 100┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄╷  │
///  │  50┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄╵  │
///  │   0┄┄┄02┄┄┄┄08┄┄┄┄14┄┄┄┄20┄┄┄   │
///  ├────────────────────────────────┤
///  │ MacBook · Yesterday 22:04 → …  │  one line per device that had a charge
///  │ iPhone · Today 17:26 → now · … │
///  ╰────────────────────────────────╯
/// ```
///
/// The axes are the summary window's `SummaryChart` axes deliberately: last
/// 24 h ending at *now*, values on the left, whole clock hours six apart, a
/// hairline and a dot where the window ends. Two views of the same day that
/// disagreed about what the x axis meant would be worse than either alone.
struct LargeWidgetView: View {
    let mac: DevicePresentation
    let phone: DevicePresentation
    /// `nil`, or older than `HistorySummary.freshnessWindow`, and the card draws
    /// its axes with nothing in them and says so.
    let history: HistorySummary?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DeviceTileLink(device: mac)
                TileDivider()
                DeviceTileLink(device: phone)
            }
            .frame(height: DeviceTile.naturalHeight)

            ChartCard(
                mac: series(.mac),
                phone: series(.iphone),
                now: now,
                isCollecting: !hasHistory
            )

            sessions
        }
        .padding(MediumWidgetView.inset)
    }

    // MARK: - Data

    private var freshHistory: HistorySummary? {
        guard let history, history.isFresh(now: now) else { return nil }
        return history
    }

    /// Fresh file *and* something in it. A summary written before the store had
    /// a day of readings has empty `series`, and an empty chart with no
    /// explanation looks like a bug rather than a beginning.
    private var hasHistory: Bool {
        guard let freshHistory else { return false }
        return freshHistory.devices.contains { !$0.series.isEmpty }
    }

    private func device(_ kind: DeviceKind) -> DeviceHistory? {
        hasHistory ? freshHistory?.device(kind: kind) : nil
    }

    private func series(_ kind: DeviceKind) -> [SeriesPoint] {
        device(kind)?.series ?? []
    }

    // MARK: - The two session lines

    /// One line per device, and nothing at all for a device that has never
    /// been on a charger while we were watching — the app's standing rule that
    /// an absence is a missing line, not a dash.
    private var sessions: some View {
        VStack(alignment: .leading, spacing: 2) {
            sessionLine(kind: .mac, name: "MacBook")
            sessionLine(kind: .iphone, name: "iPhone")
        }
    }

    @ViewBuilder
    private func sessionLine(kind: DeviceKind, name: String) -> some View {
        if let session = device(kind)?.lastSession {
            Text(verbatim: "\(name) \u{00B7} \(WidgetSessionFormat.range(session, now: now))"
                 + " \u{00B7} \(WidgetSessionFormat.percents(session))")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: - The card

/// "24 hours", a legend, and the plot. Split out so the layout above reads as
/// three bands and the chart's own machinery stays in one place.
private struct ChartCard: View {
    let mac: [SeriesPoint]
    let phone: [SeriesPoint]
    let now: Date
    let isCollecting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("24 hours", comment: "Large widget: title of the day-long chart card.")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                legend
            }
            HistoryChart(mac: mac, phone: phone, now: now)
                .overlay {
                    if isCollecting {
                        Text("Collecting history…", comment: "Large widget: shown in place of the chart until the app has a day of readings.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
        }
        .padding(EdgeInsets(top: 8, leading: 8, bottom: 6, trailing: 10))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        )
    }

    private var legend: some View {
        HStack(spacing: 5) {
            dot(ChartPalette.mac)
            Text(verbatim: "MacBook")
            Text(verbatim: "\u{00B7}")
            dot(ChartPalette.phone)
            Text(verbatim: "iPhone")
        }
        .font(.system(size: 9.5))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .fixedSize()
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 5, height: 5)
    }
}

// MARK: - The plot

/// Both devices' last 24 h in one plot, with the right-hand edge being **now**.
///
/// Everything about the axes is taken from the approved `SummaryChart`: an
/// explicit `0...100` y scale labelled 0 / 50 / 100 on the *left* over a dashed
/// hairline grid, explicit whole-hour ticks six hours apart counted back from
/// the hour `now` is in, and explicit plot insets so that no label — least of
/// all the right-most hour, which can sit right on the domain's edge — is ever
/// elided into a stray "…".
private struct HistoryChart: View {
    let mac: [SeriesPoint]
    let phone: [SeriesPoint]
    let now: Date

    /// Room kept clear at each end of the plot. The trailing figure holds half
    /// of the right-most hour label plus the end dot.
    private static let leadingInset: CGFloat = 2
    private static let trailingInset: CGFloat = 13

    private var window: ClosedRange<Date> {
        let start = now.addingTimeInterval(-24 * 3600)
        return start...max(now, start.addingTimeInterval(60))
    }

    /// Whole clock hours, six apart, counted back from the hour `now` is in and
    /// stopping before the left edge: at 20:40 that is 02, 08, 14, 20.
    private var hourTicks: [Date] {
        let calendar = Calendar.current
        let anchor = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var ticks: [Date] = []
        var tick = anchor
        while tick > window.lowerBound {
            ticks.append(tick)
            tick = tick.addingTimeInterval(-6 * 3600)
        }
        return ticks.reversed()
    }

    /// The stretches one device spent charging, as `[point, next point]`
    /// intervals merged where they touch and clipped to the window. The last
    /// point carries its span forward to `now`, since that is still what is
    /// happening.
    private func spans(_ series: [SeriesPoint], color: Color, tag: String) -> [ChargingSpan] {
        var spans: [ChargingSpan] = []
        for (index, point) in series.enumerated() where point.isCharging {
            let end = index + 1 < series.count ? series[index + 1].t : now
            if var last = spans.last, last.end >= point.t {
                last.end = end
                spans[spans.count - 1] = last
            } else {
                spans.append(ChargingSpan(start: point.t, end: end, color: color, tag: tag))
            }
        }
        return spans.compactMap { span in
            let start = max(span.start, window.lowerBound)
            let end = min(span.end, window.upperBound)
            guard end > start else { return nil }
            return ChargingSpan(start: start, end: end, color: span.color, tag: span.tag)
        }
    }

    private var allSpans: [ChargingSpan] {
        spans(mac, color: ChartPalette.mac, tag: "mac") + spans(phone, color: ChartPalette.phone, tag: "phone")
    }

    var body: some View {
        Chart {
            ForEach(allSpans) { span in
                RectangleMark(
                    xStart: .value("from", span.start),
                    xEnd: .value("to", span.end),
                    yStart: .value("low", 0),
                    yEnd: .value("high", 100)
                )
                .foregroundStyle(span.color.opacity(ChartPalette.spanAlpha))
            }

            // `series:` rather than two plain `ForEach`es, or Charts joins the
            // last Mac point to the first phone point with one long diagonal.
            ForEach(mac, id: \.t) { point in
                LineMark(
                    x: .value("time", point.t),
                    y: .value("percent", point.percent),
                    series: .value("device", "mac")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .foregroundStyle(ChartPalette.mac)
            }

            ForEach(phone, id: \.t) { point in
                LineMark(
                    x: .value("time", point.t),
                    y: .value("percent", point.percent),
                    series: .value("device", "phone")
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                .foregroundStyle(ChartPalette.phone)
            }

            // "Now": the hairline the window ends on, plus a dot on the last
            // reading each device left. Together they say which end of the
            // chart is the present without a word of text to truncate.
            RuleMark(x: .value("now", now))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(Color.secondary.opacity(0.45))

            if let last = mac.last {
                PointMark(x: .value("time", last.t), y: .value("percent", last.percent))
                    .symbolSize(24)
                    .foregroundStyle(ChartPalette.mac)
            }
            if let last = phone.last {
                PointMark(x: .value("time", last.t), y: .value("percent", last.percent))
                    .symbolSize(24)
                    .foregroundStyle(ChartPalette.phone)
            }
        }
        .chartLegend(.hidden)
        .chartYScale(domain: 0...100, range: .plotDimension(startPadding: 3, endPadding: 3))
        .chartXScale(
            domain: window,
            range: .plotDimension(startPadding: Self.leadingInset, endPadding: Self.trailingInset)
        )
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                    .foregroundStyle(Color.primary.opacity(0.18))
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text(verbatim: "\(percent)")
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: hourTicks) { value in
                AxisValueLabel(collisionResolution: .disabled) {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ChargingSpan: Identifiable {
    var start: Date
    var end: Date
    var color: Color
    var tag: String
    var id: String { "\(tag)-\(start.timeIntervalSince1970)" }
}

// MARK: - The bottom lines

/// `Yesterday 22:04 → 02:31`, `24 → 100 %`.
///
/// A deliberate twin of the summary window's `SummaryFormat`, which lives in
/// the app target and cannot be linked from a sandboxed extension. Two short
/// functions and three words; sharing them would mean promoting a view-layer
/// formatter into BatteryCore for no other reason.
enum WidgetSessionFormat {

    static let arrow = "\u{2192}"

    static func range(_ session: ChargeSession, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDateInToday(session.start) {
            day = String(localized: "Today", comment: "Large widget: the day a charge session started.")
        } else if calendar.isDateInYesterday(session.start) {
            day = String(localized: "Yesterday", comment: "Large widget: the day a charge session started.")
        } else {
            day = session.start.formatted(.dateTime.day().month(.abbreviated))
        }
        let end = session.end.map { clock($0) }
            ?? String(localized: "now", comment: "Large widget: a charge session that is still running.")
        return "\(day) \(clock(session.start)) \(arrow) \(end)"
    }

    static func percents(_ session: ChargeSession) -> String {
        "\(session.fromPercent) \(arrow) \(session.toPercent) %"
    }

    /// The locale's own clock, so a 12-hour locale gets `1:13 PM`.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}
