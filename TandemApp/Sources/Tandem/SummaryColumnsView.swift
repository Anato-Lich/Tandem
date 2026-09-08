import SwiftUI
import BatteryCore

/// Direction A — both devices at once, one column each, 924 × 640.
///
/// A column is a stack of grouped cards in the shape macOS Settings uses: a
/// tinted glyph, a label, the value hard right. Everything about one device is
/// in one column and reads top to bottom, which is what makes the side-by-side
/// worth the width — the two columns are the comparison.
///
/// Outside any window chrome, so an `ImageRenderer` can take the whole thing
/// (`tools/render-summary.swift`).
struct SummaryColumnsBody: View {
    let devices: [SummaryDevice]
    var now: Date = Date()
    /// The column drawn with a tint right now, if any.
    var highlighted: DeviceKind?

    static let columnWidth: CGFloat = 420
    static let gap: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: Self.gap) {
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 {
                    // A hairline the full height of the panel, rather than a
                    // `Divider()` — which in an `HStack` takes the parent's
                    // alignment, and this one has to run the whole way down.
                    SummaryHairline(isVertical: true)
                        .frame(maxHeight: .infinity)
                }
                SummaryColumn(presentation: SummaryPresentation(device: device, now: now))
                    .frame(width: Self.columnWidth, alignment: .topLeading)
                    .background {
                        // The "you clicked this one" tint. Deliberately weak:
                        // it answers "which column", it is not a selection.
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(SummaryPalette.blue.opacity(highlighted == device.kind ? 0.10 : 0))
                            .padding(-8)
                    }
                    .id(device.kind)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SummaryPalette.background)
    }
}

// MARK: - One column

struct SummaryColumn: View {
    let presentation: SummaryPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            hero
            batteryCard
            lastChargeCard
            todayCard
            // The chart sits on the floor of its column, so the two charts line
            // up across the window however much the blocks above them differ.
            Spacer(minLength: 0)
            chartCard
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 14) {
            SummaryRing(
                percent: presentation.percent,
                color: presentation.levelColor,
                symbolName: presentation.device.symbolName,
                size: 60,
                stroke: 6,
                symbolSize: 24,
                isCharging: presentation.isCharging
            )

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(presentation.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(SummaryPalette.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(presentation.percentText)
                        .font(.system(size: 30, weight: .semibold))
                        .monospacedDigit()
                        .kerning(-0.6)
                        .foregroundStyle(SummaryPalette.ink)
                        .fixedSize()
                }

                HStack(spacing: 6) {
                    if let chip = presentation.powerChip {
                        SummaryChip(
                            symbolName: chip.symbolName, text: chip.text,
                            tint: chip.tint, neutralForeground: chip.neutralForeground
                        )
                    }
                    if let chip = presentation.statusChip {
                        SummaryChip(
                            symbolName: chip.symbolName, text: chip.text,
                            tint: chip.tint, neutralForeground: chip.neutralForeground
                        )
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    // MARK: Battery

    /// Health, cycles, temperature and what the machine is drawing right now.
    /// A row with no number behind it is left out entirely rather than drawn as
    /// a dash: this card is the one place in the app that answers "how is the
    /// pack doing", and a placeholder there reads as an answer.
    @ViewBuilder
    private var batteryCard: some View {
        let rows = batteryRowKinds
        if !rows.isEmpty {
            SummaryCard(title: String(localized: "Battery")) {
                ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                    batteryRow(row, isLast: index == rows.count - 1)
                }
            }
        }
    }

    private enum BatteryRow: Hashable {
        case health, cycles, temperature, system
    }

    private var batteryRowKinds: [BatteryRow] {
        var rows: [BatteryRow] = []
        if presentation.healthValue != nil { rows.append(.health) }
        if presentation.cyclesValue != nil { rows.append(.cycles) }
        if presentation.temperatureValue != nil { rows.append(.temperature) }
        if presentation.systemLoadValue != nil { rows.append(.system) }
        return rows
    }

    @ViewBuilder
    private func batteryRow(_ row: BatteryRow, isLast: Bool) -> some View {
        switch row {
        case .health:
            SummaryRow(
                symbolName: "heart.fill", tint: SummaryPalette.green,
                label: String(localized: "Health"), value: presentation.healthValue ?? "",
                sub: presentation.healthCapacity, showsSeparator: !isLast
            )
        case .cycles:
            SummaryRow(
                symbolName: "arrow.triangle.2.circlepath", tint: SummaryPalette.blue,
                label: String(localized: "Cycles"), value: presentation.cyclesValue ?? "",
                showsSeparator: !isLast
            )
        case .temperature:
            SummaryRow(
                symbolName: "thermometer.medium", tint: SummaryPalette.amber,
                label: String(localized: "Temperature"), value: presentation.temperatureValue ?? "",
                showsSeparator: !isLast
            )
        case .system:
            SummaryRow(
                symbolName: "cpu", tint: SummaryPalette.purple,
                label: String(localized: "System"), value: presentation.systemLoadValue ?? "",
                showsSeparator: !isLast
            ) {
                // The trace of the last dozen readings, left of the exact
                // number it belongs to. It draws nothing at all until there are
                // two figures to make a shape out of.
                SummarySparkline(values: presentation.systemLoadSeries, width: 90, height: 22)
                    .padding(.trailing, 10)
            }
        }
    }

    // MARK: Last charge

    private var lastChargeCard: some View {
        SummaryCard(title: String(localized: "Last charge")) {
            if let range = presentation.lastChargeRange, let value = presentation.lastChargeValue {
                SummaryRow(
                    symbolName: "calendar", tint: SummaryPalette.green,
                    label: range, value: value,
                    sub: presentation.lastChargeDetail, showsSeparator: false
                )
            } else {
                Text(SummaryPresentation.noSessions)
                    .font(.system(size: 11.5))
                    .foregroundStyle(SummaryPalette.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
            }
        }
    }

    // MARK: Today

    @ViewBuilder
    private var todayCard: some View {
        let cells = todayCells
        if !cells.isEmpty {
            SummaryCard(title: String(localized: "Today")) {
                HStack(spacing: 0) {
                    ForEach(cells, id: \.caption) { cell in
                        SummaryStatCell(value: cell.value, caption: cell.caption)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
    }

    private var todayCells: [(value: String, caption: String)] {
        var cells: [(String, String)] = []
        if let range = presentation.todayRange { cells.append((range, String(localized: "range"))) }
        if let charger = presentation.todayOnCharger { cells.append((charger, String(localized: "on charger"))) }
        if let cycles = presentation.todayCycles { cells.append((cycles, String(localized: "cycles"))) }
        if let draw = presentation.todayDraw { cells.append((draw, String(localized: "draw"))) }
        return cells
    }

    // MARK: The 24 h chart

    /// The card carries its own two titles and legends (`SummaryChartCard`),
    /// so unlike the blocks above it there is no `SummaryCard` label over it.
    private var chartCard: some View {
        SummaryChartCard(
            bins: presentation.bins,
            now: presentation.now,
            contentWidth: SummaryColumnsBody.columnWidth - 2 * SummaryChartCard.horizontalPadding,
            levelHeight: 110,
            powerHeight: 70
        )
    }
}
