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

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.16), lineWidth: lineWidth)
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
