import SwiftUI
import Charts
import BatteryCore

// MARK: - The palette

/// The summary window's colours, straight out of the approved mock-ups
/// (`docs/design/summary/gen.py`).
///
/// Hard-coded rather than semantic (`.secondary`, `Color.orange`) on purpose:
/// the window is a dark panel of its own, drawn the same way whatever the
/// system appearance is, and every one of these values appears in the design
/// file by number. The popover and the widget keep using the system colours —
/// they sit on material the system supplies.
enum SummaryPalette {
    static let background = Color(rgb: 0x1C1C1E)
    static let card = Color(rgb: 0x2C2C2E)
    /// The selected segment of the tab bar.
    static let raised = Color(rgb: 0x48484A)
    static let hairline = Color(rgb: 0x3D3D40)
    /// The unfilled part of a level ring.
    static let track = Color(rgb: 0x3A3A3C)
    static let ink = Color(rgb: 0xF5F5F7)
    static let muted = Color(rgb: 0x98989D)

    static let green = Color(rgb: 0x30D158)
    static let amber = Color(rgb: 0xFF9F0A)
    static let red = Color(rgb: 0xFF453A)
    static let blue = Color(rgb: 0x64D2FF)
    static let purple = Color(rgb: 0xBF5AF2)

    /// A chip or a tinted icon plate: the accent at 13 % over the card.
    static let tintAlpha: Double = 0.13
    /// The neutral chip's plate, `#ffffff14` in the mock.
    static let neutralChip = Color.white.opacity(0.08)
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

/// Level → colour, the app's one rule (red under 20 %, amber under 50 %, green
/// above), in the summary window's own palette. `batteryLevelColor` stays as it
/// is for the popover and the menu bar, which draw in system colours.
func summaryLevelColor(_ percent: Int?) -> Color {
    guard let percent else { return SummaryPalette.muted }
    if percent < 20 { return SummaryPalette.red }
    if percent < 50 { return SummaryPalette.amber }
    return SummaryPalette.green
}

// MARK: - Which layout

/// The two approved shapes of the summary window, chosen by the user from the
/// popover's overflow menu and remembered in `@AppStorage("summaryLayout")`.
///
/// They answer different questions — "how are both of my devices doing" against
/// "how is *this* device doing" — and the mock-up review would not pick one, so
/// both are built and the setting is the answer.
enum SummaryLayout: String, CaseIterable, Identifiable {
    /// Direction A: both devices at once, 924 × 640.
    case columns
    /// Direction B: one device at a time behind a tab bar, 480 × 640.
    case tabs

    var id: String { rawValue }

    static let storageKey = "summaryLayout"

    var size: CGSize {
        switch self {
        case .columns: return CGSize(width: 924, height: 640)
        case .tabs: return CGSize(width: 480, height: 640)
        }
    }

    var title: String {
        switch self {
        case .columns: return String(localized: "Two columns")
        case .tabs: return String(localized: "Tabs")
        }
    }
}

// MARK: - The ring

/// The level ring: a track, a rounded arc from twelve o'clock, the device glyph
/// in the middle, and an amber bolt badge riding the top-right while charging.
///
/// A device with no reading at all draws the bare track — never a full circle of
/// red at 0 %, which is what an unknown level used to look like.
struct SummaryRing: View {
    let percent: Int?
    let color: Color
    var symbolName: String
    var size: CGFloat = 60
    var stroke: CGFloat = 6
    var symbolSize: CGFloat = 24
    var isCharging: Bool = false

    /// The badge's diameter, and the near-black the bolt is punched out of it
    /// in — the mock's `#1B1408`, so the glyph reads on amber at 10 pt.
    private var badgeDiameter: CGFloat { size * 0.3 }

    var body: some View {
        ZStack {
            Circle().stroke(SummaryPalette.track, lineWidth: stroke)
            if let percent {
                Circle()
                    .trim(from: 0, to: max(0.004, min(1, Double(percent) / 100)))
                    .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Image(systemName: symbolName)
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(SummaryPalette.ink)
        }
        .padding(stroke / 2)
        .frame(width: size, height: size)
        .overlay(alignment: .topTrailing) {
            if isCharging {
                ZStack {
                    Circle().fill(SummaryPalette.amber)
                    Image(systemName: "bolt.fill")
                        .font(.system(size: badgeDiameter * 0.56, weight: .bold))
                        .foregroundStyle(Color(rgb: 0x1B1408))
                }
                .frame(width: badgeDiameter, height: badgeDiameter)
                .offset(x: 2, y: -2)
            }
        }
    }
}

// MARK: - Chips

/// One of the two chips under a device's name: the power chip and the status
/// chip. `tint` non-nil paints both the plate and the text (the amber charging
/// chip); nil is the neutral white-8-% plate.
struct SummaryChip: View {
    var symbolName: String?
    let text: String
    var tint: Color?
    /// The neutral chip's text: muted for the power chip, ink for the status
    /// chip, per the mock.
    var neutralForeground: Color = SummaryPalette.ink

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
        .lineLimit(1)
        .foregroundStyle(tint ?? neutralForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(tint.map { $0.opacity(SummaryPalette.tintAlpha) } ?? SummaryPalette.neutralChip)
        )
    }
}

// MARK: - Cards and their rows

/// A grouped card: an optional uppercase section label, then the rows on the
/// `#2C2C2E` plate with a 12 pt radius.
struct SummaryCard<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                SummarySectionLabel(text: title)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 6)
            }
            VStack(spacing: 0) { content }
                .background(SummaryPalette.card)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

struct SummarySectionLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.84)
            .foregroundStyle(SummaryPalette.muted)
    }
}

/// The hairline between two rows of a card: **one device pixel**, always, on
/// the same grid in every card and both layouts.
///
/// It is drawn this way because the obvious version is visibly wrong. A `0.5`
/// pt rule is half a pixel on a 1x display and one pixel on a 2x one, and where
/// it lands depends on how tall the rows above it happened to come out — and
/// those heights come from text, so they are fractional and all different. A
/// separator that happens to land on a whole device pixel draws as a crisp,
/// full-strength line; its neighbour, half a pixel off, is smeared across two
/// pixels at half alpha each and reads as *thicker and brighter*. That is
/// exactly what "the line between Cycles and Temperature is heavier than the
/// others" was.
///
/// So: `1 / displayScale` for the thickness (one pixel on any display), and
/// `SummaryRow`/`SummaryBigRow` pin their content to whole-point heights so
/// every separator starts on the same sub-pixel offset as the one above it.
struct SummaryHairline: View {
    /// `true` for the full-height rule between the two columns.
    var isVertical = false

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Rectangle()
            .fill(SummaryPalette.hairline)
            .frame(
                width: isVertical ? 1 / displayScale : nil,
                height: isVertical ? nil : 1 / displayScale
            )
    }
}

/// The rounded, tinted plate a row's glyph sits on: the accent at 13 %, the
/// glyph in the accent itself.
struct SummaryTintedIcon: View {
    let symbolName: String
    let color: Color
    var size: CGFloat = 26

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color.opacity(SummaryPalette.tintAlpha))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbolName)
                    .font(.system(size: size * 0.54, weight: .medium))
                    .foregroundStyle(color)
            }
    }
}

/// One row of a card in the two-column layout: tinted glyph, label over an
/// optional sub-line, an optional trailing accessory (the sparkline), and the
/// value hard right.
struct SummaryRow<Accessory: View>: View {
    let symbolName: String
    let tint: Color
    let label: String
    let value: String
    var sub: String?
    var showsSeparator: Bool = true
    @ViewBuilder var accessory: Accessory

    /// Whole points, so the hairline under the row starts on the same device
    /// pixel offset as every other one (see `SummaryHairline`). Tall enough for
    /// the 26 pt glyph, and for a 12.5 pt label over a 10.5 pt sub-line.
    private var contentHeight: CGFloat { sub == nil ? 26 : 30 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SummaryTintedIcon(symbolName: symbolName, color: tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(SummaryPalette.ink)
                    if let sub {
                        Text(sub)
                            .font(.system(size: 10.5))
                            .foregroundStyle(SummaryPalette.muted)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                accessory

                Text(value)
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(SummaryPalette.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: contentHeight)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if showsSeparator { SummaryHairline() }
        }
    }
}

extension SummaryRow where Accessory == EmptyView {
    init(
        symbolName: String,
        tint: Color,
        label: String,
        value: String,
        sub: String? = nil,
        showsSeparator: Bool = true
    ) {
        self.init(
            symbolName: symbolName, tint: tint, label: label, value: value,
            sub: sub, showsSeparator: showsSeparator, accessory: { EmptyView() }
        )
    }
}

/// The tabbed layout's row: the same idea one size up — 30 pt glyph, 13 pt
/// label, 17 pt value — because there is one device on screen and the room to
/// spend on it.
struct SummaryBigRow: View {
    let symbolName: String
    let tint: Color
    let label: String
    let value: String
    var sub: String?
    var showsSeparator: Bool = true

    /// The same whole-point rule as `SummaryRow`, one size up.
    private var contentHeight: CGFloat { sub == nil ? 30 : 32 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                SummaryTintedIcon(symbolName: symbolName, color: tint, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(SummaryPalette.ink)
                    if let sub {
                        Text(sub)
                            .font(.system(size: 11))
                            .foregroundStyle(SummaryPalette.muted)
                    }
                }
                .monospacedDigit()
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(value)
                    .font(.system(size: 17, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(SummaryPalette.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
            .frame(height: contentHeight)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if showsSeparator { SummaryHairline() }
        }
    }
}

/// A value over its caption — the "Today" grid's cell.
struct SummaryStatCell: View {
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(SummaryPalette.ink)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(SummaryPalette.muted)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - The sparkline

/// The last dozen system-load readings, drawn with no axis and no scale.
///
/// It is deliberately not a time series — `DeviceHistory.systemLoadSeries` is
/// consecutive *readings*, which the skip rule makes uneven — so it carries no
/// grid, no labels and no zero line: it is the shape of the recent trace beside
/// a number that is exact, and nothing more. Fewer than two points is not a
/// shape, and draws nothing.
struct SummarySparkline: View {
    let values: [Double]
    var color: Color = SummaryPalette.purple
    var width: CGFloat = 90
    var height: CGFloat = 22

    var body: some View {
        if values.count >= 2 {
            Canvas { context, size in
                let low = values.min() ?? 0
                let high = values.max() ?? 1
                let span = max(0.0001, high - low)
                let points = values.enumerated().map { index, value in
                    CGPoint(
                        x: 1 + CGFloat(index) * (size.width - 2) / CGFloat(values.count - 1),
                        y: size.height - 3 - CGFloat((value - low) / span) * (size.height - 6)
                    )
                }

                var line = Path()
                line.addLines(points)

                var area = line
                area.addLine(to: CGPoint(x: size.width - 1, y: size.height))
                area.addLine(to: CGPoint(x: 1, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(color.opacity(0.14)))

                context.stroke(
                    line,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round)
                )

                if let last = points.last {
                    context.fill(
                        Path(ellipseIn: CGRect(x: last.x - 2.2, y: last.y - 2.2, width: 4.4, height: 4.4)),
                        with: .color(color)
                    )
                }
            }
            .frame(width: width, height: height)
        }
    }
}

// MARK: - The 24 h chart

/// The last 24 h, with the right-hand edge being **now**: a percent line over
/// amber-shaded charging stretches, dashed grid lines at 0 / 50 / 100 labelled
/// on the left, real clock hours every six hours counted back from now, and a
/// hairline plus a dot where the window ends.
///
/// The time axis is the last 24 hours rather than the calendar day, because the
/// question this chart answers is "what happened to the battery since this time
/// yesterday". The labels are therefore whole clock hours *inside* that moving
/// window (20:40 now -> 02 - 08 - 14 - 20), not a 0-24 ruler and not a stride
/// Charts picks for itself.
///
/// Charging is shaded rather than coloured into the line, because the line's
/// own colour would then be saying two things at once - and everywhere else in
/// this app colour means level and nothing but level.
struct SummaryChart: View {
    let series: [SeriesPoint]
    var now: Date = Date()
    var levelColor: Color = SummaryPalette.green
    /// A fixed plot height, or `nil` to take whatever room the card has left
    /// (the tabbed layout, where the chart card is the floor of the window).
    var height: CGFloat? = 110

    /// The smallest a filling chart is allowed to get.
    static let minimumHeight: CGFloat = 118

    /// How much of the plot area is kept clear at each end, so no axis label is
    /// ever elided into the "..." this chart used to grow at its bottom-right
    /// corner. The trailing figure has to hold half of the right-most hour
    /// label (which can sit right on `now`) plus the end dot.
    private static let leadingInset: CGFloat = 2
    private static let trailingInset: CGFloat = 14

    /// The 24 h window. The upper bound is `now` exactly; the room the labels
    /// need is taken out of the plot area (`plotDimension` padding), not out of
    /// the domain, so "the right edge is this second" stays literally true.
    private var window: ClosedRange<Date> {
        let start = now.addingTimeInterval(-24 * 3600)
        return start...max(now, start.addingTimeInterval(60))
    }

    /// Whole clock hours, six hours apart, counted back from the hour `now` is
    /// in and stopping before the left edge: at 20:40 that is 02, 08, 14, 20.
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

    /// The stretches during which the device was charging, as `[point, next
    /// point]` intervals merged where they touch and clipped to the window. The
    /// last point carries the span forward to `now`, since that is still what is
    /// happening.
    private var chargingSpans: [SummarySpan] {
        var spans: [SummarySpan] = []
        for (index, point) in series.enumerated() where point.isCharging {
            let end = index + 1 < series.count ? series[index + 1].t : now
            if var last = spans.last, last.end >= point.t {
                last.end = end
                spans[spans.count - 1] = last
            } else {
                spans.append(SummarySpan(start: point.t, end: end))
            }
        }
        return spans.compactMap { span in
            let start = max(span.start, window.lowerBound)
            let end = min(span.end, window.upperBound)
            return end > start ? SummarySpan(start: start, end: end) : nil
        }
    }

    var body: some View {
        if let height {
            plot.frame(height: height)
        } else {
            plot.frame(minHeight: Self.minimumHeight, maxHeight: .infinity)
        }
    }

    private var plot: some View {
        Chart {
            ForEach(chargingSpans) { span in
                RectangleMark(
                    xStart: .value("from", span.start),
                    xEnd: .value("to", span.end),
                    yStart: .value("low", 0),
                    yEnd: .value("high", 100)
                )
                .foregroundStyle(SummaryPalette.amber.opacity(0.14))
            }

            ForEach(series, id: \.t) { point in
                LineMark(
                    x: .value("time", point.t),
                    y: .value("percent", point.percent)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                .foregroundStyle(levelColor)
            }

            // "Now": the hairline the window ends on, and the dot on the last
            // reading we hold. Together they say which end of the chart is the
            // present without a word of text to truncate.
            RuleMark(x: .value("now", now))
                .lineStyle(StrokeStyle(lineWidth: 1))
                .foregroundStyle(SummaryPalette.muted.opacity(0.45))

            if let last = series.last {
                PointMark(
                    x: .value("time", last.t),
                    y: .value("percent", last.percent)
                )
                .symbolSize(30)
                .foregroundStyle(levelColor)
            }
        }
        .chartYScale(domain: 0...100, range: .plotDimension(startPadding: 3, endPadding: 3))
        .chartXScale(
            domain: window,
            range: .plotDimension(startPadding: Self.leadingInset, endPadding: Self.trailingInset)
        )
        .chartYAxis {
            AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6, dash: [2, 3]))
                    .foregroundStyle(SummaryPalette.hairline)
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text(verbatim: "\(percent)")
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(SummaryPalette.muted)
                            .fixedSize()
                    }
                }
            }
        }
        .chartXAxis {
            // Explicit ticks and explicit, `fixedSize` label content: the
            // automatic six-hour stride put a tick on the very edge of the
            // domain, and Charts elided that label to a lone "..." in the
            // bottom-right corner whenever the plot was narrow enough.
            AxisMarks(values: hourTicks) { value in
                AxisValueLabel(collisionResolution: .disabled) {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour(.twoDigits(amPM: .omitted)))
                            .font(.system(size: 9.5))
                            .monospacedDigit()
                            .foregroundStyle(SummaryPalette.muted)
                            .fixedSize()
                    }
                }
            }
        }
    }
}

struct SummarySpan: Identifiable {
    var start: Date
    var end: Date
    var id: Date { start }
}
