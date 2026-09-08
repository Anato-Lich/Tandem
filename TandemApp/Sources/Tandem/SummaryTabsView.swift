import SwiftUI
import BatteryCore

/// Direction B — one device at a time behind a segmented tab bar, 480 × 640.
///
/// Half the width of the two-column layout and everything twice the size: a
/// widget tile is clicked to see *that* device, and this is the shape that
/// answers only that question. The tab bar still carries both percents, so the
/// other device is one glance away without a switch.
struct SummaryTabsBody: View {
    let devices: [SummaryDevice]
    var now: Date = Date()
    var selection: DeviceKind = .mac
    var onSelect: (DeviceKind) -> Void = { _ in }

    /// The panel's own inset, subtracted from the window width when a card
    /// needs to know how wide its content will come out (`SummaryChartCard`).
    static let bodyPadding: CGFloat = 18

    private var selected: SummaryDevice? {
        devices.first { $0.kind == selection } ?? devices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            tabBar
            if let selected {
                let presentation = SummaryPresentation(device: selected, now: now)
                hero(presentation)
                rows(presentation)
                // The chart card takes the whole of the room the list leaves,
                // rather than being pushed to the floor by a `Spacer` with a
                // dead gap above it. Only the "no history yet" card, which is
                // one sentence tall, still gets pushed down.
                if !presentation.hasChart { Spacer(minLength: 0) }
                chartCard(presentation)
            }
        }
        .padding(Self.bodyPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(SummaryPalette.background)
    }

    // MARK: The tab bar

    private var tabBar: some View {
        HStack(spacing: 3) {
            ForEach(devices) { device in
                segment(device)
            }
        }
        .padding(3)
        .background(SummaryPalette.card)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func segment(_ device: SummaryDevice) -> some View {
        let isSelected = device.kind == (selected?.kind ?? selection)
        return HStack(spacing: 6) {
            Image(systemName: device.symbolName)
                .font(.system(size: 15, weight: .regular))
            Text(device.name)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            Text(device.percent.map { "\($0) %" } ?? StatColumn.emDash)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
            if device.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(SummaryPalette.amber)
            }
        }
        .foregroundStyle(isSelected ? SummaryPalette.ink : SummaryPalette.muted)
        .padding(7)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? SummaryPalette.raised : .clear)
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(device.kind) }
    }

    // MARK: The hero

    private func hero(_ presentation: SummaryPresentation) -> some View {
        HStack(alignment: .center, spacing: 16) {
            SummaryRing(
                percent: presentation.percent,
                color: presentation.levelColor,
                symbolName: presentation.device.symbolName,
                size: 84,
                stroke: 8,
                symbolSize: 32,
                isCharging: presentation.isCharging
            )

            VStack(alignment: .leading, spacing: 4) {
                Text(presentation.percentText)
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                    .kerning(-1.2)
                    .foregroundStyle(SummaryPalette.ink)
                if let subtitle = presentation.heroSubtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(SummaryPalette.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let load = presentation.systemLoadValue {
                VStack(alignment: .trailing, spacing: 3) {
                    Text(load)
                        .font(.system(size: 20, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(SummaryPalette.ink)
                    Text(String(localized: "system"))
                        .font(.system(size: 10.5))
                        .foregroundStyle(SummaryPalette.muted)
                    SummarySparkline(values: presentation.systemLoadSeries, width: 110, height: 22)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
    }

    // MARK: The four rows

    private func rows(_ presentation: SummaryPresentation) -> some View {
        let rows = rowKinds(presentation)
        return SummaryCard {
            ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                bigRow(row, presentation, isLast: index == rows.count - 1)
            }
        }
    }

    private enum BigRow: Hashable {
        case health, temperature, lastCharge, today
    }

    /// `lastCharge` is always there — it has an honest empty line of its own —
    /// while the other three drop out when the store has no number for them.
    private func rowKinds(_ presentation: SummaryPresentation) -> [BigRow] {
        var rows: [BigRow] = []
        if presentation.healthValue != nil { rows.append(.health) }
        if presentation.temperatureValue != nil { rows.append(.temperature) }
        rows.append(.lastCharge)
        if presentation.today != nil { rows.append(.today) }
        return rows
    }

    @ViewBuilder
    private func bigRow(_ row: BigRow, _ presentation: SummaryPresentation, isLast: Bool) -> some View {
        switch row {
        case .health:
            SummaryBigRow(
                symbolName: "heart.fill", tint: SummaryPalette.green,
                label: String(localized: "Battery health"), value: presentation.healthValue ?? "",
                sub: presentation.healthSub, showsSeparator: !isLast
            )
        case .temperature:
            SummaryBigRow(
                symbolName: "thermometer.medium", tint: SummaryPalette.amber,
                label: String(localized: "Temperature"), value: presentation.temperatureValue ?? "",
                sub: presentation.temperatureNote, showsSeparator: !isLast
            )
        case .lastCharge:
            SummaryBigRow(
                symbolName: "calendar", tint: SummaryPalette.blue,
                label: String(localized: "Last charge"),
                value: presentation.lastChargeValue ?? "",
                sub: presentation.lastChargeWhen ?? SummaryPresentation.noSessions,
                showsSeparator: !isLast
            )
        case .today:
            SummaryBigRow(
                symbolName: "clock", tint: SummaryPalette.purple,
                label: String(localized: "Today"), value: presentation.todayOnCharger ?? "",
                sub: presentation.todaySub, showsSeparator: !isLast
            )
        }
    }

    // MARK: The chart

    private func chartCard(_ presentation: SummaryPresentation) -> some View {
        SummaryChartCard(
            bins: presentation.bins,
            now: presentation.now,
            contentWidth: SummaryLayout.tabs.size.width
                - 2 * Self.bodyPadding
                - 2 * SummaryChartCard.horizontalPadding,
            levelHeight: 150,
            powerHeight: 92,
            // The card is the floor of this window: it takes the room the list
            // above it leaves over, and the level plot is what grows into it.
            fillsHeight: presentation.hasChart
        )
    }
}
