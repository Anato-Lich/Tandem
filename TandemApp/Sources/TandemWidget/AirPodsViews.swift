import SwiftUI

/// What one half of the medium (and large) widget shows: a battery tile, or
/// the AirPods tile. Picked per slot in Edit Widget (`TilesIntent`).
enum TileSlot {
    case device(DevicePresentation, bars: [TileBar])
    case airpods(AirPodsStatus?, now: Date)

    init(_ device: SlotDevice, snapshot: TandemSnapshot?, now: Date, bars: DayBars) {
        switch device {
        case .mac: self = .device(DevicePresentation(kind: .mac, status: snapshot?.mac, now: now), bars: bars.mac)
        case .iphone: self = .device(DevicePresentation(kind: .iphone, status: snapshot?.phone, now: now), bars: bars.phone)
        case .airpods: self = .airpods(snapshot?.airpods, now: now)
        }
    }
}

struct SlotTile: View {
    let slot: TileSlot

    var body: some View {
        switch slot {
        case let .device(device, bars): DeviceTileLink(device: device, bars: bars)
        case let .airpods(status, now): AirPodsTile(status: status, now: now)
        }
    }
}

/// The AirPods in a medium tile's three bands, at the battery tile's sizes:
///
/// ```
///  ( ◖◗ ) in case            dual ring + state (or 🕑 14:02 when not live)
///  100 L  100 R  75 case      in place of the day strip
///  100 %                      the emptier bud
/// ```
struct AirPodsTile: View {
    let status: AirPodsStatus?
    let now: Date

    private var dimming: Double { status == nil ? 0.45 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 8) {
                DualRingView(status: status, size: DeviceTile.ringSize)
                topLine
                Spacer(minLength: 0)
            }
            Spacer(minLength: DeviceTile.band)
            partsLine
                .frame(maxWidth: .infinity, minHeight: DayBarsView.height, alignment: .bottomLeading)
            Spacer(minLength: DeviceTile.band)
            Text(AirPodsText.percent(status?.budsLevel))
                .font(.system(size: DeviceTile.percentSize, weight: .semibold))
                .monospacedDigit()
                .kerning(-0.5)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .opacity(dimming)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var topLine: some View {
        Group {
            if let status {
                if !status.isLive(now: now) {
                    HStack(spacing: 3) {
                        Image(systemName: "clock").font(.system(size: 13))
                        Text(verbatim: status.lastHeard.map(DevicePresentation.clock) ?? DevicePresentation.emDash)
                    }
                } else if status.leftCharging || status.rightCharging {
                    // Charging buds are buds in the case: the flags come from the
                    // closed-lid advert (DECISIONS D2).
                    Text(AirPodsText.inCase)
                }
            } else {
                Text(DevicePresentation.noDataLabel)
            }
        }
        .font(.system(size: DeviceTile.topSize))
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }

    @ViewBuilder
    private var partsLine: some View {
        if let status {
            ViewThatFits(in: .horizontal) {
                parts(status, spacing: 10)
                parts(status, spacing: 6)
                parts(status, spacing: 4).minimumScaleFactor(0.7)
            }
            .font(.system(size: 13))
            .lineLimit(1)
        }
    }

    private func parts(_ status: AirPodsStatus, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            AirPodsText.part(status.left, charging: status.leftCharging, label: "L")
            AirPodsText.part(status.right, charging: status.rightCharging, label: "R")
            AirPodsText.part(status.caseLevel, charging: status.caseCharging, label: AirPodsText.caseLabel)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The wording and colouring the three AirPods views share.
enum AirPodsText {
    static func percent(_ level: Int?) -> String { level.map { "\($0) %" } ?? DevicePresentation.emDash }

    /// `100 L`: the number semibold — orange while that part charges, red
    /// under 20 % — and the label muted. `— L` when the part is unknown.
    static func part(_ level: Int?, charging: Bool, label: String, unit: Bool = false) -> Text {
        let number = level.map { unit ? "\($0) %" : "\($0)" } ?? DevicePresentation.emDash
        // A full bud still flags "charging" in the case; orange there would
        // say power is going in when none is.
        let color: Color = switch level {
        case nil: .secondary
        case let level? where charging && level < 100: BarPalette.charging
        case let level? where level < DevicePresentation.lowLevel: .red
        default: .primary
        }
        let numberText = Text(verbatim: number).fontWeight(.semibold).foregroundStyle(color)
        let labelText = Text(verbatim: label).foregroundStyle(.secondary)
        return Text("\(numberText) \(labelText)")
    }

    static var inCase: String {
        String(localized: "in case", comment: "Widget: the AirPods are in their charging case.")
    }

    static var caseLabel: String {
        String(localized: "case", comment: "Widget: the AirPods charging case, as in \"75 case\".")
    }
}

/// The large widget's AirPods strip: glyph, then L / R / case each over a
/// 5 pt bar.
struct AirPodsStrip: View {
    let status: AirPodsStatus

    static let height: CGFloat = 34

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "airpods")
                .font(.system(size: 20))
                .frame(width: 22)
            column(status.left, charging: status.leftCharging, label: "L")
            column(status.right, charging: status.rightCharging, label: "R")
            column(status.caseLevel, charging: status.caseCharging, label: AirPodsText.caseLabel)
        }
        .frame(height: Self.height)
    }

    private func column(_ level: Int?, charging: Bool, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            AirPodsText.part(level, charging: charging, label: label, unit: true)
                .font(.system(size: 13))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(RingView.track)
                    if let level {
                        Capsule()
                            .fill(DevicePresentation.levelColor(level))
                            .frame(width: proxy.size.width * min(1, max(0, Double(level) / 100)))
                    }
                }
            }
            .frame(height: 5)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `systemSmall` "Accessories": the AirPods ring, the emptier bud's percent
/// and the case. The mock-up's right column is Apple Watch, which has no data
/// source yet, so the AirPods column stands alone, centred.
struct AccessoriesWidgetView: View {
    let status: AirPodsStatus?

    var body: some View {
        VStack(spacing: 8) {
            DualRingView(status: status, size: 60, outerRadius: 26, outerWidth: 5.5,
                         innerRadius: 18, innerWidth: 4.5, symbolSize: 18)
            VStack(spacing: 3) {
                Text(AirPodsText.percent(status?.budsLevel))
                    .font(.system(size: 21, weight: .semibold))
                    .kerning(-0.4)
                HStack(spacing: 3) {
                    Image(systemName: "airpods.chargingcase").font(.system(size: 10))
                    Text(status == nil ? DevicePresentation.noDataLabel : AirPodsText.percent(status?.caseLevel))
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
            }
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .opacity(status == nil ? 0.45 : 1)
    }
}
