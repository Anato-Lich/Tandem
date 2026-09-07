import SwiftUI

/// One device's tile: the layout the medium widget puts either side of its
/// hairline, and the same one the large widget stacks above its chart.
///
/// ```
///  ╭──────────────────────╮
///  │ ( ▭ )  62/140 W      │   top row:    ring + the power line
///  │                      │   Spacer
///  │ 90 %    80 % · 14 min│   bottom row: percent + status, one baseline
///  ╰──────────────────────╯
/// ```
///
/// Both slots collapse on their own (see `DevicePresentation`), so an iPhone on
/// battery is a ring, a percent and a time, and nothing is left holding space.
///
/// It lives on its own rather than inside `MediumWidgetView` because the large
/// family reuses it verbatim: the two widgets' tiles are the same picture, and
/// the only way to keep them that way is for them to be the same view.
struct DeviceTile: View {
    let device: DevicePresentation

    private static let ringSize: CGFloat = 60
    private static let ringStroke: CGFloat = 6.5
    private static let ringSymbol: CGFloat = 24

    /// The tallest this tile ever wants: ring, the gap, and the percent line.
    /// The medium widget lets it fill instead; the large widget, which has a
    /// chart to feed underneath, pins the row to this.
    static let naturalHeight: CGFloat = 104

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 13) {
                ring
                powerLine
                Spacer(minLength: 0)
            }
            Spacer(minLength: 2)
            bottomRow
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(device.dimming)
    }

    private var ring: some View {
        ZStack {
            RingView(percent: device.percent, color: device.levelColor, lineWidth: Self.ringStroke)
            Image(systemName: device.symbolName)
                .font(.system(size: Self.ringSymbol))
        }
        .frame(width: Self.ringSize, height: Self.ringSize)
        .overlay(alignment: .topTrailing) {
            if device.showsStaleBadge {
                RingBadge(symbol: "exclamationmark", diameter: 16).offset(x: 1, y: -1)
            } else if device.isCharging {
                RingBadge(symbol: "bolt.fill", diameter: 16).offset(x: 1, y: -1)
            }
        }
    }

    /// The one secondary line, top-aligned against the ring. Charging watts are
    /// the only coloured run on the tile besides the ring itself; the plugged-
    /// in-but-idle case leads with a plug glyph instead of a colour, so the
    /// number reads as an offer rather than a flow.
    @ViewBuilder
    private var powerLine: some View {
        if let power = device.powerText {
            Self.label(power, plug: device.showsPlugGlyph)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(device.isCharging
                                 ? AnyShapeStyle(Color.orange)
                                 : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .lineLimit(1)
                // "62/140 W" has to survive beside a 60 pt ring in half of a
                // 344 pt widget.
                .minimumScaleFactor(0.6)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// One `Text`, so the glyph and the number scale together under
    /// `minimumScaleFactor` instead of drifting apart.
    private static func label(_ text: String, plug: Bool) -> Text {
        plug ? Text(Image(systemName: "powerplug")) + Text(" \(text)") : Text(text)
    }

    /// Percent big at the left; the one status baseline-aligned with it at the
    /// right, so the two tiles' numbers sit on a single line across the widget.
    private var bottomRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(device.percentText)
                .font(.system(size: 34, weight: .semibold))
                .monospacedDigit()
                .kerning(-0.5)
            Spacer(minLength: 2)
            if let status = device.statusText {
                Text(status)
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
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

    var body: some View {
        if linksEnabled {
            Link(destination: MediumWidgetView.summaryURL(device.kind)) {
                DeviceTile(device: device)
            }
        } else {
            DeviceTile(device: device)
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
/// one line of tech Batteries has no room for set beside the ring.
struct MediumWidgetView: View {
    let mac: DevicePresentation
    let phone: DevicePresentation

    /// The tile inset. `TandemWidgetEntryView` cancels WidgetKit's own content
    /// margins for this family so this is the real distance to the widget edge.
    static let inset: CGFloat = 14

    var body: some View {
        HStack(spacing: 10) {
            DeviceTileLink(device: mac)
            TileDivider()
            DeviceTileLink(device: phone)
        }
        .padding(Self.inset)
    }

    static func summaryURL(_ kind: DeviceKind) -> URL {
        // Constructed from a string constant that cannot fail to parse.
        URL(string: "tandem://summary/\(kind.rawValue)") ?? URL(fileURLWithPath: "/")
    }
}
