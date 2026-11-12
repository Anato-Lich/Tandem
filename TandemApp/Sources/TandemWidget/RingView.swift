import SwiftUI

/// The one ring both sizes draw: a track plus a rounded level arc starting at
/// twelve o'clock. Sized by the caller's `.frame`, so the same view is the
/// 86 pt outer ring, the 62 pt inner one and the 60 pt medium tile ring.
///
/// A `nil` percent draws the track alone: a device that has never been seen has
/// no level, and a dot of red at 0 % would read as a reading.
struct RingView: View {
    let percent: Int?
    let color: Color
    let lineWidth: CGFloat

    private var fraction: Double? {
        percent.map { min(1, max(0, Double($0) / 100)) }
    }

    static let track = Color.primary.opacity(0.16)

    var body: some View {
        ZStack {
            Circle()
                .stroke(Self.track, lineWidth: lineWidth)
            if let fraction {
                Circle()
                    // A hair of trim even at 0 %, so the rounded cap still shows
                    // the ring is alive rather than vanishing entirely.
                    .trim(from: 0, to: max(0.004, fraction))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
        .padding(lineWidth / 2)
    }
}

/// The AirPods ring: the outer ring split into two halves with a gap at top
/// and bottom — right bud clockwise from the top on the right, left bud
/// mirrored on the left — and a thinner full ring inside for the case.
/// Butt caps on the halves so the gaps stay crisp. Geometry is the approved
/// mock-up's (airpods-canvas `MediumThree` / `SmallAccessories`).
struct DualRingView: View {
    let status: AirPodsStatus?
    var size: CGFloat = 52
    var outerRadius: CGFloat = 22
    var outerWidth: CGFloat = 5
    var innerRadius: CGFloat = 15
    var innerWidth: CGFloat = 4
    var symbolSize: CGFloat = 16

    /// 3 pt of arc either side of twelve and of six o'clock.
    private var gap: CGFloat { 3 / (2 * .pi * outerRadius) }

    var body: some View {
        ZStack {
            half(status?.right, mirrored: false)
            half(status?.left, mirrored: true)
            RingView(percent: status?.caseLevel,
                     color: DevicePresentation.levelColor(status?.caseLevel),
                     lineWidth: innerWidth)
                .frame(width: 2 * innerRadius + innerWidth, height: 2 * innerRadius + innerWidth)
            Image(systemName: "airpods")
                .font(.system(size: symbolSize))
        }
        .frame(width: size, height: size)
    }

    private func half(_ percent: Int?, mirrored: Bool) -> some View {
        let span = 0.5 - 2 * gap
        return ZStack {
            Circle()
                .trim(from: gap, to: gap + span)
                .stroke(RingView.track, lineWidth: outerWidth)
            if let percent {
                Circle()
                    .trim(from: gap, to: gap + span * max(0.004, min(1, Double(percent) / 100)))
                    .stroke(DevicePresentation.levelColor(percent), lineWidth: outerWidth)
            }
        }
        .rotationEffect(.degrees(-90))
        .scaleEffect(x: mirrored ? -1 : 1)
        .frame(width: 2 * outerRadius, height: 2 * outerRadius)
    }
}

/// The orange disc that sits on the top-right of a medium tile's ring: a bolt
/// while the device charges, an exclamation mark when its reading has gone
/// stale. Never both — a device that has stopped reporting is not charging as
/// far as anyone here knows.
struct RingBadge: View {
    let symbol: String
    var diameter: CGFloat = 18
    /// Orange for charging and stale; the plug badge takes the mains blue so
    /// the three badges read as three different states at a glance.
    var tint: Color = .orange

    var body: some View {
        ZStack {
            Circle().fill(tint)
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.55, weight: .bold))
                .foregroundStyle(Color.black.opacity(0.8))
        }
        .frame(width: diameter, height: diameter)
    }
}
