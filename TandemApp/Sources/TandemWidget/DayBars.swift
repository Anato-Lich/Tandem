import Foundation
import SwiftUI

/// One two-hour column of a tile's day strip.
///
/// `percent` is `nil` when nothing is known about those two hours, which is
/// drawn as a stub rather than as a zero — the same "an absence is not a
/// reading" rule the ring and the percent follow. A column whose four bins were
/// all `.unknown` carries that state too, so the stub is drawn in the track's
/// own grey rather than in a colour that would claim the battery was on the
/// pack, or on the wall, through hours nobody watched.
struct TileBar: Equatable, Sendable {
    var percent: Int?
    var state: HistoryBinState
}

/// The 24 h strip in the middle of a medium tile: `DeviceHistory.bins24h`
/// folded from 48 half hours down to 12 two-hour columns.
///
/// **Why fold at all.** The summary window has 396 pt for 48 bars; a medium
/// tile has about 150, which is three points a bar before the gaps. Twelve is
/// what fits at the mock-up's 2 pt gap and still reads as a day — one column
/// per two hours, so "this morning" and "last night" are findable by eye.
///
/// **How.** Each group of four consecutive half-hour bins becomes one column.
/// Its `percent` is the last one in the group that has a figure — bins carry
/// the level forward across a *short* hole (`ChargeSessionBuilder.bins`), so
/// this is the level the device was at when the two hours ended. Its `state` is
/// the state the group spent most of its time in; every bin is the same half
/// hour wide, so that is a plain majority of the four, and a tie goes to the
/// last bin, exactly as a tie inside one bin goes to its last reading.
///
/// **Unknown bins do not vote.** A half hour nobody watched has no state to
/// contribute, so the majority is taken over the bins that were watched, and
/// two hours in which *none* of them were is itself an unknown column: no
/// percent, no colour, a stub in the track. That is the difference between "the
/// Mac's display slept and the phone went unpolled" and "the phone was flat".
struct DayBars: Equatable, Sendable {

    /// Two-hour columns across the day.
    static let count = 12

    var mac: [TileBar] = []
    var phone: [TileBar] = []

    init(mac: [TileBar] = [], phone: [TileBar] = []) {
        self.mac = mac
        self.phone = phone
    }

    /// Straight off a `history-summary.json`. A file that is missing, or older
    /// than `HistorySummary.freshnessWindow`, yields empty strips — the tile
    /// then draws the bare track, which says "no day here" without drawing a
    /// day that ended two hours ago as if it were this one.
    init(history: HistorySummary?, now: Date) {
        guard let history, history.isFresh(now: now) else { return }
        mac = Self.fold(history.device(kind: .mac)?.bins24h ?? [])
        phone = Self.fold(history.device(kind: .iphone)?.bins24h ?? [])
    }

    subscript(kind: DeviceKind) -> [TileBar] {
        switch kind {
        case .mac: mac
        case .iphone: phone
        }
    }

    /// 48 half-hour bins → 12 two-hour columns, oldest first.
    ///
    /// Written for any bin count rather than for 48 alone: the group size is
    /// rounded up, the newest bins are the ones that survive, and a short run
    /// is left-padded with empty columns so "now" stays at the right-hand edge
    /// whatever the store had to offer.
    static func fold(_ bins: [HistoryBin]) -> [TileBar] {
        guard !bins.isEmpty else { return [] }
        let size = max(1, Int((Double(bins.count) / Double(count)).rounded(.up)))
        let origin = bins.count - count * size

        return (0..<count).map { column in
            let lower = origin + column * size
            let range = max(0, lower)..<max(0, min(bins.count, lower + size))
            guard !range.isEmpty else { return TileBar(percent: nil, state: .unknown) }
            let group = bins[range].filter { $0.state != .unknown }
            // Every half hour of it a hole: the column is one too.
            guard !group.isEmpty else { return TileBar(percent: nil, state: .unknown) }

            var weights: [HistoryBinState: Int] = [:]
            for bin in group { weights[bin.state, default: 0] += 1 }
            // Non-nil: `group` is non-empty.
            let fallback = group.last?.state ?? .battery
            let state = weights
                .sorted { lhs, rhs in
                    if lhs.value != rhs.value { return lhs.value > rhs.value }
                    return lhs.key == fallback
                }
                .first?.key ?? fallback

            return TileBar(
                percent: group.reversed().first { $0.percent != nil }?.percent,
                state: state
            )
        }
    }
}

/// The day strip's three colours, by number rather than by system name.
///
/// The three states have to be told apart at 10 pt wide, and the tile draws
/// them over whatever material the widget host supplies; `Color.green` and
/// `Color.blue` shift with the appearance and with the system accent, and two
/// of them landing close together would make the strip unreadable. These are
/// the mock-up's values (`docs/design/widget/gen.py`) and the summary window's
/// (`SummaryPalette`), so the two views of one day are the same picture.
enum BarPalette {
    static let battery = Color(rgb: 0x30D158)
    static let charging = Color(rgb: 0xFF9F0A)
    static let mains = Color(rgb: 0x64D2FF)
    /// Two hours nobody watched, and the bare strip they are a piece of: the
    /// same grey, because a stub in the track's colour reads as "nothing here"
    /// rather than as a very flat battery.
    static let track = Color.primary.opacity(0.12)

    /// The blue the plugged-in-but-not-charging watts are written in, matched
    /// to the `mains` bars they explain.
    static let plugged = mains

    static func color(_ state: HistoryBinState) -> Color {
        switch state {
        case .battery: battery
        case .charging: charging
        case .mains: mains
        case .unknown: track
        }
    }
}

/// The strip itself: one rounded column per two hours, the newest at full
/// strength and the rest a shade back, over the tile's full width.
///
/// With nothing to draw it is an empty track rather than a hole — a widget with
/// a band of blank tile in the middle of it looks broken, and the track says
/// "no day yet" in the same shape the day will arrive in.
struct DayBarsView: View {
    let bars: [TileBar]

    static let height: CGFloat = 36
    static let gap: CGFloat = 2
    static let radius: CGFloat = 1.2
    /// What a column with no reading at all — and one whose every half hour was
    /// a hole — shows: enough to see, not enough to mistake for a level.
    static let stub: CGFloat = 2

    var body: some View {
        if bars.isEmpty {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(BarPalette.track)
                .frame(height: Self.height)
        } else {
            HStack(alignment: .bottom, spacing: Self.gap) {
                ForEach(Array(bars.enumerated()), id: \.offset) { offset, bar in
                    RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                        .fill(BarPalette.color(bar.state))
                        .opacity(offset == bars.count - 1 ? 1 : 0.7)
                        .frame(maxWidth: .infinity)
                        .frame(height: Self.barHeight(bar))
                }
            }
            .frame(height: Self.height, alignment: .bottom)
        }
    }

    private static func barHeight(_ bar: TileBar) -> CGFloat {
        // Both tests, not just the percent: an unknown column has no level by
        // construction, and saying so here is what keeps the two in step if one
        // ever arrives without the other.
        guard bar.state != .unknown, let percent = bar.percent else { return stub }
        return max(stub, CGFloat(min(100, max(0, percent))) / 100 * height)
    }
}
