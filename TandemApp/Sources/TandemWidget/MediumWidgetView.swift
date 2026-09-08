import SwiftUI

/// One device's tile: the layout the medium widget puts either side of its
/// hairline, and the same one the large widget stacks above its chart.
///
/// ```
///  ╭──────────────────────────╮
///  │ ( ▭ )⚡ 62/140 W         │   ring + badge, and one line beside it
///  │ ▁▁▂▄█████▆▅▃▂            │   the day, twelve two-hour columns
///  │ 32 %        80 % · 27 min│   percent + status, one baseline
///  ╰──────────────────────────╯
/// ```
///
/// Three bands, and every state in the approved matrix
/// (`docs/design/widget/StatesMac.dc.html`, `StatesPhone.dc.html`) is those
/// same three bands saying different things — never a band that disappears, so
/// the two tiles either side of the hairline always line up:
///
/// | state | beside the ring | bottom right |
/// | --- | --- | --- |
/// | charging | `62/140 W`, amber | `80 % · 27 min` |
/// | on battery | `−13 W` / `on battery` | `4:19` |
/// | on the wall, holding | 🔌 `13/140 W`, blue | `charged` / `on hold` |
/// | silent > 10 min | `silent since 14:32` | `14:32` |
/// | never seen | `no data` | — |
///
/// It lives on its own rather than inside `MediumWidgetView` because the large
/// family reuses it verbatim: the two widgets' tiles are the same picture, and
/// the only way to keep them that way is for them to be the same view.
struct DeviceTile: View {
    let device: DevicePresentation
    /// The device's day, already folded to twelve columns. Empty draws the
    /// bare track — see `DayBarsView`.
    var bars: [TileBar] = []

    private static let ringSize: CGFloat = 52
    private static let ringStroke: CGFloat = 6
    private static let ringSymbol: CGFloat = 22
    /// The mock-up's 13 pt, taken up on the user's instruction: this is the one
    /// line of tech on the tile and it was too quiet to read at arm's length.
    private static let topSize: CGFloat = 15
    private static let percentSize: CGFloat = 30
    private static let statusSize: CGFloat = 12.5
    /// The least air either side of the bars. The tile is taller than its
    /// content in the medium family and shorter in nothing, so these are
    /// floors, not gaps.
    private static let band: CGFloat = 6

    /// The tallest this tile ever wants: ring, the day, the percent line and
    /// the two bands between them. The medium widget lets it fill instead; the
    /// large widget, which has a chart to feed underneath, pins the row to this.
    static let naturalHeight: CGFloat = ringSize + band + DayBarsView.height + band + 36

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                ring
                topLine.opacity(device.dimming)
                Spacer(minLength: 0)
            }
            Spacer(minLength: Self.band)
            DayBarsView(bars: bars).opacity(device.dimming)
            Spacer(minLength: Self.band)
            bottomRow.opacity(device.dimming)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// The ring dims with the rest of a silent tile; the badge does not. It is
    /// the one mark on the widget whose whole job is to be noticed from across
    /// the room, and dimming the warning along with what it warns about would
    /// be exactly backwards.
    private var ring: some View {
        ZStack {
            RingView(percent: device.percent, color: device.levelColor, lineWidth: Self.ringStroke)
            Image(systemName: device.symbolName)
                .font(.system(size: Self.ringSymbol))
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
        .opacity(device.dimming)
        .overlay(alignment: .topTrailing) {
            if device.showsSilentBadge {
                RingBadge(symbol: "exclamationmark", diameter: 16).offset(x: 1, y: -1)
            } else if device.isCharging {
                RingBadge(symbol: "bolt.fill", diameter: 16).offset(x: 1, y: -1)
            } else if device.showsPlugGlyph {
                // Mains without charging: the plug lives on the ring like the
                // bolt does, so the power line beside it stays a bare number
                // that fits at full size.
                RingBadge(symbol: "powerplug.fill", diameter: 16, tint: BarPalette.plugged).offset(x: 1, y: -1)
            }
        }
    }

    /// The one secondary line, centred against the ring. Colour carries the
    /// meaning: amber is power going into the pack, blue is power the wall is
    /// carrying and the pack is not taking, and everything else is quiet.
    @ViewBuilder
    private var topLine: some View {
        if let text = device.topText {
            Self.label(text, plug: device.showsPlugGlyph)
                .font(.system(size: Self.topSize, weight: Self.weight(device.topKind)))
                .monospacedDigit()
                .foregroundStyle(Self.style(device.topKind))
                .lineLimit(1)
                // Only "silent since 14:32" ever needs to shrink; every
                // power line fits at full size beside the ring, and the user
                // wants those read at the size the mock-up says.
                .minimumScaleFactor(device.topKind == .plain ? 0.6 : 1.0)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func weight(_ kind: DevicePresentation.TopLineKind) -> Font.Weight {
        switch kind {
        case .charging, .plugged: .semibold
        case .plain: .regular
        }
    }

    private static func style(_ kind: DevicePresentation.TopLineKind) -> AnyShapeStyle {
        switch kind {
        case .charging: AnyShapeStyle(BarPalette.charging)
        case .plugged: AnyShapeStyle(BarPalette.plugged)
        case .plain: AnyShapeStyle(HierarchicalShapeStyle.secondary)
        }
    }

    /// One `Text`, so the glyph and the number scale together under
    /// `minimumScaleFactor` instead of drifting apart.
    private static func label(_ text: String, plug: Bool) -> Text {
        // The plug moved onto the ring as a badge; the line is text only.
        Text(text)
    }

    /// Percent big at the left; the one status baseline-aligned with it at the
    /// right, so the two tiles' numbers sit on a single line across the widget.
    private var bottomRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(device.percentText)
                .font(.system(size: Self.percentSize, weight: .semibold))
                .monospacedDigit()
                .kerning(-0.5)
            Spacer(minLength: 2)
            if let status = device.statusText {
                Text(status)
                    .font(.system(size: Self.statusSize))
                    .monospacedDigit()
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }
}

/// A `DeviceTile` that is its own tap target.
///
/// The medium and large widgets show two devices side by side, so a single
/// `widgetURL` for the whole thing would answer "which one did you mean?" with
/// "both" no matter which half was clicked; the summary window then highlights
/// the column that was asked for (`tandem://summary/mac` | `/iphone`). The
/// small widget, which is one glance at both devices, keeps its whole-widget
/// `widgetURL`.
struct DeviceTileLink: View {
    @Environment(\.tileLinksEnabled) private var linksEnabled
    let device: DevicePresentation
    var bars: [TileBar] = []

    var body: some View {
        if linksEnabled {
            Link(destination: MediumWidgetView.summaryURL(device.kind)) {
                DeviceTile(device: device, bars: bars)
            }
        } else {
            DeviceTile(device: device, bars: bars)
        }
    }
}

/// Off only in `tools/render-widget.swift`.
///
/// `ImageRenderer` has no widget host behind it, so it cannot honour a `Link`
/// and draws the "not permitted" glyph across the whole tile instead — every
/// export of a layout containing one comes out as two yellow no-entry signs.
/// The switch is here rather than in the tool because the tool renders the
/// widget's *own* views on purpose (that is the point of the exports), and the
/// only thing it has to opt out of is the tap target.
private struct TileLinksKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var tileLinksEnabled: Bool {
        get { self[TileLinksKey.self] }
        set { self[TileLinksKey.self] = newValue }
    }
}

/// The hairline between the two tiles.
struct TileDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.18))
            .frame(width: 0.5)
            .frame(maxHeight: .infinity)
    }
}

/// `systemMedium`: two tiles either side of a hairline, each modelled on the
/// system Batteries widget — ring top-left, big percent bottom-left — with the
/// one line of tech Batteries has no room for set beside the ring, and the
/// device's last 24 h between them.
struct MediumWidgetView: View {
    let mac: DevicePresentation
    let phone: DevicePresentation
    /// Both devices' days, folded to twelve columns each. Empty — no
    /// `history-summary.json`, or one more than two hours old — and both tiles
    /// draw the bare track.
    var bars = DayBars()

    /// The tile inset. `TandemWidgetEntryView` cancels WidgetKit's own content
    /// margins for this family so this is the real distance to the widget edge.
    static let inset: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            DeviceTileLink(device: mac, bars: bars.mac)
            TileDivider()
            DeviceTileLink(device: phone, bars: bars.phone)
        }
        .padding(Self.inset)
    }

    static func summaryURL(_ kind: DeviceKind) -> URL {
        // Constructed from a string constant that cannot fail to parse.
        URL(string: "tandem://summary/\(kind.rawValue)") ?? URL(fileURLWithPath: "/")
    }
}
