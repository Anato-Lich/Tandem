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

/// Level → colour, the app's one rule (green, red under 20 %), in the summary
/// window's own palette. `batteryLevelColor` stays as it is for the popover and
/// the menu bar, which draw in system colours.
///
/// Amber deliberately does not appear here: in this window it already means
/// "charging" on every bar of the 24 h card (`HistoryBinState.summaryColor`),
/// and a ring that turned the same colour at 49 % said the machine was on a
/// charger when it was not.
func summaryLevelColor(_ percent: Int?) -> Color {
    guard let percent else { return SummaryPalette.muted }
    return percent < lowBatteryLevel ? SummaryPalette.red : SummaryPalette.green
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

    /// Both windows grew by 140 pt when the 24 h card became two plots
    /// (`SummaryChartCard`): the level plot alone used to be the whole card, and
    /// at 640 pt the power plot under it had nowhere to go but off the bottom
    /// edge. Nothing above the card moved — the approved cards keep their sizes,
    /// their padding and their order — and the tabbed layout still spends
    /// whatever is left over on the level plot.
    var size: CGSize {
        switch self {
        case .columns: return CGSize(width: 924, height: 780)
        case .tabs: return CGSize(width: 480, height: 780)
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

extension HistoryBinState {

    /// The one rule these two plots follow: colour means **state**, never
    /// level. Green is the pack, amber is a charge, blue is the wall carrying
    /// the machine with nothing going into the pack. (Everywhere else in the
    /// app colour means level — a ring, a bar, a menu-bar glyph — and that is
    /// exactly why the chart may not: a bar that changed colour as the battery
    /// fell would be saying two things at once.)
    var summaryColor: Color {
        switch self {
        case .battery: return SummaryPalette.green
        case .charging: return SummaryPalette.amber
        case .mains: return SummaryPalette.blue
        // Nobody was watching: the hairline the grid lines are drawn in, which
        // is the one colour in this window that already means "structure, not
        // measurement". It never becomes a bar — see `unknownStubs`.
        case .unknown: return SummaryPalette.hairline
        }
    }
}

/// One bar of either plot, already resolved to points.
private struct SummaryChartBar: Identifiable {
    /// The middle of the bin, which is where the bar is centred.
    var mid: Date
    var value: Double
    var width: CGFloat
    var color: Color
    var opacity: Double
    var id: Date { mid }
}

/// One half hour with nothing in it, already resolved to points: where its bar
/// would have stood, and how wide it would have been.
private struct SummaryStub: Identifiable {
    var index: Int
    var x: CGFloat
    var width: CGFloat
    var id: Int { index }
}

/// One point of the system-load line. `run` breaks the line where the data
/// does: a stretch nobody measured is a hole, not a straight line across it.
private struct SummaryLoadPoint: Identifiable {
    var t: Date
    var value: Double
    var run: Int
    var id: Date { t }
}

/// The summary window's 24 h card: half-hour bars of battery level over a
/// second plot of where the watts were going, on one shared time axis
/// (`docs/design/chart/ChartB2.dc.html`).
///
/// **Bars, not a line.** `DeviceHistory.bins24h` is 48 fixed half hours, so
/// every bar is the same width, a gap in the data is visible as a gap, and each
/// bar can carry the state the device was in for most of that half hour. The
/// line this replaced could do none of that: a `SeriesPoint` is a reading at
/// whatever uneven instant the skip rule produced one (NOTES.md §15.2), and a
/// line drawn through them says "we were here the whole time" about an hour
/// nobody watched.
///
/// **Three states.** Green on the pack, amber charging, blue on the wall and
/// holding. The third is not a nicety: a Mac parked at 90 % on a 140 W brick is
/// neither charging nor discharging, and this is the only view in the app that
/// can say so. An iPhone never reports it, and needs no separate code path.
///
/// **And a fourth non-state.** A half hour nobody watched (`.unknown`, see
/// `ChargeSessionBuilder.carryWindow`) gets no bar at all — a 2 pt stub at the
/// baseline in the hairline colour, and a "no data" key in the legend as soon
/// as the window holds one. The phone's silence while the Mac's display sleeps
/// used to be drawn as a flat shelf of carried level ending in a cliff; a level
/// nobody measured has no height, and the honest mark for it is the width of
/// the slot and none of its height.
///
/// **The time axis is shared and labelled once**, at the bottom of the power
/// plot, on whole clock hours six hours apart counted back from now — because
/// the question is "what happened since this time yesterday", not "what did the
/// calendar day look like". Both plots reserve the same width for their y
/// labels (`axisLabelWidth`), which is what keeps the two x axes on the same
/// grid however wide the numbers beside them get.
struct SummaryChartCard: View {
    let bins: [HistoryBin]
    var now: Date = Date()
    /// The width the card's content gets, i.e. the column minus this card's own
    /// horizontal padding. Handed in rather than measured: both layouts are
    /// fixed-size windows (`SummaryLayout.size`, `.windowResizability(.contentSize)`),
    /// and a `GeometryReader` here would feed a layout pass back through the
    /// bar widths for no gain — and would not have settled at all by the time
    /// `tools/render-summary.swift` takes its picture.
    var contentWidth: CGFloat = 396
    /// The level plot's height, and its floor when `fillsHeight` is set.
    var levelHeight: CGFloat = 110
    var powerHeight: CGFloat = 70
    /// The tabbed layout, where the card is the floor of the window: the level
    /// plot takes whatever room is left over, the power plot stays put.
    var fillsHeight: Bool = false

    /// The card's own horizontal padding, which is what a layout has to
    /// subtract from its column to hand `contentWidth` in.
    static let horizontalPadding: CGFloat = 12

    /// The gap between two bars, in points, straight out of the design file
    /// (`gen.py`: `x + 1`, `width - 2`).
    private static let barGap: CGFloat = 2
    private static let barRadius: CGFloat = 1.5
    /// Every y label is drawn into a box this wide, in both plots, so the two
    /// time axes line up whatever the numbers are.
    private static let axisLabelWidth: CGFloat = 22
    /// That box plus the gap Charts leaves between an axis and its plot.
    private static let axisGutter: CGFloat = 6
    /// Kept clear at each end of the *data*, so the right-most hour label and
    /// the "80 %" tag have room and no label is ever elided into the "…" this
    /// chart used to grow in its bottom-right corner.
    private static let leadingInset: CGFloat = 2
    private static let trailingInset: CGFloat = 14

    /// Fewer than two bins with a percent in them is not a chart. The axes are
    /// still drawn — an empty grid says "this is where it will appear" — with
    /// one line of text across them.
    var hasData: Bool { bins.filter { $0.percent != nil }.count >= 2 }

    /// Does the window contain half hours nobody watched? Only then is the
    /// "no data" key worth the space in the legend.
    var hasUnknownBins: Bool { bins.contains { $0.state == .unknown } }

    /// How tall a stub stands under an unknown half hour: enough to see that
    /// the slot exists, far too little to be read as a level.
    private static let stubHeight: CGFloat = 2

    // MARK: Geometry

    /// The window: 24 h ending exactly at `now`. The bins are pinned to the
    /// clock inside it, so the newest one is the half hour `now` falls in and
    /// the oldest starts up to half an hour after the left edge.
    private var window: ClosedRange<Date> {
        let start = now.addingTimeInterval(-24 * 3600)
        return start...max(now, start.addingTimeInterval(60))
    }

    /// The room the data itself gets, once the y labels and the two insets are
    /// taken out of the card's width.
    private var dataWidth: CGFloat {
        max(48, contentWidth - Self.axisLabelWidth - Self.axisGutter - Self.leadingInset - Self.trailingInset)
    }

    /// One bin's share of that, and the bar drawn inside it.
    private var binWidth: CGFloat { dataWidth / CGFloat(max(1, bins.count)) }
    private var barWidth: CGFloat { max(1, binWidth - Self.barGap) }

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

    /// A bin's right edge — its own half hour, except for the newest one, which
    /// ends at `now` and is therefore usually a part-bin. Its bar is narrowed
    /// to match rather than being drawn full width past the present.
    private func geometry(_ bin: HistoryBin, isLast: Bool) -> (mid: Date, width: CGFloat)? {
        let end = min(bin.start.addingTimeInterval(ChargeSessionBuilder.binWidth), max(now, bin.start))
        let span = end.timeIntervalSince(bin.start)
        guard span > 0 else { return nil }
        let fraction = min(1, span / ChargeSessionBuilder.binWidth)
        let width: CGFloat = isLast ? max(1, binWidth * CGFloat(fraction) - Self.barGap) : barWidth
        return (bin.start.addingTimeInterval(span / 2), width)
    }

    // MARK: The three series

    private var levelBars: [SummaryChartBar] {
        guard hasData else { return [] }
        return bins.enumerated().compactMap { index, bin in
            guard let percent = bin.percent else { return nil }
            let isLast = index == bins.count - 1
            guard let box = geometry(bin, isLast: isLast) else { return nil }
            return SummaryChartBar(
                mid: box.mid,
                value: Double(percent),
                width: box.width,
                color: bin.state.summaryColor,
                // The newest bar at full strength, everything behind it a
                // shade back: the eye lands on "now" without a label.
                opacity: isLast ? 1 : 0.85
            )
        }
    }

    /// The half hours nobody watched, in points rather than in data units: a
    /// bar of 0 % would be a measurement, and a bar of 2 % would be a lie about
    /// a battery. So the stubs are drawn *over* the plot, at its baseline, at
    /// the x offsets the bars themselves use — the same `binWidth` arithmetic
    /// the bar widths come from, which is why this needs no `GeometryReader`.
    private var unknownStubs: [SummaryStub] {
        guard hasData else { return [] }
        return bins.enumerated().compactMap { index, bin in
            guard bin.state == .unknown else { return nil }
            guard let box = geometry(bin, isLast: index == bins.count - 1) else { return nil }
            return SummaryStub(
                index: index,
                x: CGFloat(index) * binWidth + (binWidth - box.width) / 2,
                width: box.width
            )
        }
    }

    /// What the wall was putting in. Amber while charging; a thin blue bar
    /// while the machine is merely being carried by the adapter; **nothing at
    /// all** on battery, where there is no wall and no number.
    private var powerBars: [SummaryChartBar] {
        guard hasData else { return [] }
        return bins.enumerated().compactMap { index, bin in
            guard let watts = bin.powerInW, watts > 0, bin.state != .battery else { return nil }
            let isLast = index == bins.count - 1
            guard let box = geometry(bin, isLast: isLast) else { return nil }
            return SummaryChartBar(
                mid: box.mid,
                value: watts,
                width: box.width,
                color: bin.state == .charging ? SummaryPalette.amber : SummaryPalette.blue,
                opacity: bin.state == .charging ? (isLast ? 1 : 0.85) : 0.55
            )
        }
    }

    /// What the machine itself was drawing, in purple over the bars.
    private var loadPoints: [SummaryLoadPoint] {
        guard hasData else { return [] }
        var points: [SummaryLoadPoint] = []
        var run = 0
        var previousIndex: Int?
        for (index, bin) in bins.enumerated() {
            guard let watts = bin.systemLoadW else { continue }
            if let previousIndex, index > previousIndex + 1 { run += 1 }
            previousIndex = index
            guard let box = geometry(bin, isLast: index == bins.count - 1) else { continue }
            points.append(SummaryLoadPoint(t: box.mid, value: watts, run: run))
        }
        return points
    }

    /// The power plot's ceiling: whatever the tallest of the two series needs,
    /// rounded up to a round number, so the axis reads 0 · 10 · 20 rather than
    /// 0 · 6.5 · 13.
    var powerCeiling: Double {
        let bars = bins.compactMap(\.powerInW).max() ?? 0
        let load = bins.compactMap(\.systemLoadW).max() ?? 0
        return Self.niceCeiling(max(bars, load))
    }

    static func niceCeiling(_ value: Double) -> Double {
        let steps: [Double] = [20, 50, 100, 200, 500, 1000]
        if let step = steps.first(where: { $0 >= value }) { return step }
        return (value / 500).rounded(.up) * 500
    }

    // MARK: The card

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(
                String(localized: "Charge · 24 hours"),
                [
                    .bar(SummaryPalette.green, String(localized: "on battery")),
                    .bar(SummaryPalette.amber, String(localized: "charging")),
                    .bar(SummaryPalette.blue, String(localized: "on mains"))
                ]
                // Only when there is something for it to explain: a key for a
                // mark that is not on the plot is noise.
                + (hasUnknownBins ? [.bar(SummaryPalette.hairline, String(localized: "no data"))] : [])
            )
            level
            header(
                String(localized: "Power"),
                [
                    .bar(SummaryPalette.amber, String(localized: "from adapter, W")),
                    .line(SummaryPalette.purple, String(localized: "system, W"))
                ]
            )
            .padding(.top, 2)
            power
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil, alignment: .top)
        .background(SummaryPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(_ title: String, _ items: [SummaryLegendItem]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            SummarySectionLabel(text: title)
            Spacer(minLength: 4)
            SummaryLegend(items: items)
        }
    }

    // MARK: The level plot

    @ViewBuilder
    private var level: some View {
        let plot = Chart {
            ForEach(levelBars) { bar in
                BarMark(
                    x: .value("time", bar.mid),
                    yStart: .value("from", 0),
                    yEnd: .value("percent", bar.value),
                    width: .fixed(bar.width)
                )
                .cornerRadius(Self.barRadius)
                .foregroundStyle(bar.color.opacity(bar.opacity))
            }

            // The 80 % line: where a charge should stop, and the level this
            // app's one timer counts down to.
            RuleMark(y: .value("80 %", 80))
                .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
                .foregroundStyle(SummaryPalette.ink.opacity(0.5))
                .annotation(
                    position: .top,
                    alignment: .trailing,
                    spacing: 1,
                    // Without this the tag is cropped against the plot's edge
                    // — the rule ends exactly there — and what is left reads as
                    // a smudge rather than as a number.
                    overflowResolution: .init(x: .fit(to: .plot), y: .disabled)
                ) {
                    Text(verbatim: "80 %")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(SummaryPalette.muted)
                        .padding(.horizontal, 3)
                        .background(
                            // The bars run right up to the present, so the tag
                            // sits on a scrap of the card's own colour rather
                            // than half-legible over a bar.
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(SummaryPalette.card.opacity(0.85))
                        )
                        .fixedSize()
                }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis { axisMarks([0, 50, 100]) }
        .chartXScale(
            domain: window,
            range: .plotDimension(startPadding: Self.leadingInset, endPadding: Self.trailingInset)
        )
        // Labelled once, under the power plot: two rulers under one another
        // would only invite the eye to check they agree.
        .chartXAxis(.hidden)
        // The stubs sit on the plot's own baseline: the x axis is hidden, so
        // the bottom of this view *is* y = 0, and the leading pad is the y
        // labels, their gutter and the scale's own start padding — the three
        // numbers `dataWidth` is defined by.
        .overlay(alignment: .bottomLeading) {
            ZStack(alignment: .bottomLeading) {
                ForEach(unknownStubs) { stub in
                    RoundedRectangle(cornerRadius: Self.barRadius / 2, style: .continuous)
                        .fill(SummaryPalette.hairline)
                        .frame(width: stub.width, height: Self.stubHeight)
                        .offset(x: stub.x)
                }
            }
            .padding(.leading, Self.axisLabelWidth + Self.axisGutter + Self.leadingInset)
            .allowsHitTesting(false)
        }
        .overlay(alignment: .center) {
            if !hasData {
                Text(String(localized: "Collecting history…"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(SummaryPalette.muted)
            }
        }

        if fillsHeight {
            plot.frame(minHeight: levelHeight, maxHeight: .infinity)
        } else {
            plot.frame(height: levelHeight)
        }
    }

    // MARK: The power plot

    private var power: some View {
        Chart {
            ForEach(powerBars) { bar in
                BarMark(
                    x: .value("time", bar.mid),
                    yStart: .value("from", 0),
                    yEnd: .value("watts", bar.value),
                    width: .fixed(bar.width)
                )
                .cornerRadius(Self.barRadius)
                .foregroundStyle(bar.color.opacity(bar.opacity))
            }

            ForEach(loadPoints) { point in
                LineMark(
                    x: .value("time", point.t),
                    y: .value("watts", point.value),
                    series: .value("run", point.run)
                )
                .interpolationMethod(.monotone)
                .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .foregroundStyle(SummaryPalette.purple)
            }
        }
        .chartYScale(domain: 0...powerCeiling)
        .chartYAxis { axisMarks([0, powerCeiling / 2, powerCeiling]) }
        .chartXScale(
            domain: window,
            range: .plotDimension(startPadding: Self.leadingInset, endPadding: Self.trailingInset)
        )
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
        .frame(height: powerHeight)
    }

    /// Both plots' y axis: a solid hairline at each value, the number on the
    /// **left** in a box of a fixed width — which is what keeps the two plots'
    /// time axes on the same grid.
    private func axisMarks(_ values: [Double]) -> some AxisContent {
        AxisMarks(position: .leading, values: values) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                .foregroundStyle(SummaryPalette.hairline)
            AxisValueLabel {
                Text(verbatim: SummaryChartCard.axisText(value.as(Double.self)))
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(SummaryPalette.muted)
                    .fixedSize()
                    .frame(width: SummaryChartCard.axisLabelWidth, alignment: .trailing)
            }
        }
    }

    /// `13`, not `13.0`, and `12.5` where a halved odd ceiling needs it.
    static func axisText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value == value.rounded() ? "\(Int(value))" : String(format: "%.1f", value)
    }
}

// MARK: - The legend

/// One legend entry: a filled block for a bar series, a short rule for a line.
struct SummaryLegendItem: Identifiable {
    var color: Color
    var text: String
    var isLine: Bool
    var id: String { text }

    static func bar(_ color: Color, _ text: String) -> SummaryLegendItem {
        SummaryLegendItem(color: color, text: text, isLine: false)
    }

    static func line(_ color: Color, _ text: String) -> SummaryLegendItem {
        SummaryLegendItem(color: color, text: text, isLine: true)
    }
}

/// The row of keys beside a plot's title. The swatch is the shape of the mark
/// it stands for — a block for bars, a rule for the line — because a row of
/// identical dots would need the words to be read before the plot can be.
struct SummaryLegend: View {
    let items: [SummaryLegendItem]

    /// Four keys is the level plot with a "no data" entry in it, and at that
    /// point the row is wide enough to push the section label beside it onto a
    /// second line. Closing the gaps buys back the width the fourth key costs.
    private var spacing: CGFloat { items.count > 3 ? 8 : 12 }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(items) { item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(item.color)
                        .frame(
                            width: item.isLine ? 10 : 7,
                            height: item.isLine ? 2.5 : 10
                        )
                    Text(item.text)
                        .font(.system(size: 10.5))
                        .foregroundStyle(SummaryPalette.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
    }
}
