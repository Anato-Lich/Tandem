import SwiftUI
import BatteryCore

/// One row in the popover: monochrome icon, name, a charging bolt (or, for an
/// overdue iPhone, an orange warning glyph in its place), a right-aligned
/// percent, a 6 pt level-colored bar, and three fixed telemetry columns
/// (system draw, adapter, time-to-80%/time-left) that never wrap. Falls back to a
/// "not reachable" row when the device has never been seen at all. Staleness
/// is otherwise silent — no "updated N ago" text anywhere in the row.
struct DeviceRowView: View {
    let kind: DeviceKind
    let status: DeviceStatus?
    /// The typed reason the last poll for this device failed
    /// (`TandemSnapshot.macError` / `.phoneError`), `nil` on a healthy poll.
    let error: MonitorError?
    /// "Now" as the popover sees it. `PopoverContentView` drives this from a
    /// `TimelineView` ticking once a minute, so the time-to-80 % column counts
    /// down between polls instead of being a number frozen at the last read
    /// (`DeviceStatus.etaTo80At` is an absolute deadline — NOTES.md §14).
    var now: Date = Date()

    /// Indent for content below the header row, so it lines up with the
    /// device name (icon width 16 + header spacing, rounded to the approved
    /// mock's 28 pt).
    private static let contentIndent: CGFloat = 28

    /// How old the iPhone's `lastSeen` may get before the header swaps its
    /// bolt for a warning glyph and "Resync" unlocks in the footer menu.
    /// Matches `TandemModel.phoneNeedsResync`.
    static let phoneAttentionThreshold: TimeInterval = 300

    var body: some View {
        if let status {
            knownRow(status)
        } else {
            unknownRow
        }
    }

    // MARK: - Known device

    private func knownRow(_ status: DeviceStatus) -> some View {
        // Percent and the charging bolt (both in `headerRow`) always stay at
        // full opacity; only the power/adapter/time columns dim when their
        // basis is a degraded-tier reading or an aging one (NOTES.md §13.2).
        let detailsAreStale = status.isPartial || (status.detailAge.map { $0 > 120 } ?? false)

        return VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                headerRow(status)
                levelBar(percent: status.reading.percent)
            }

            HStack(spacing: 18) {
                StatColumnView(column: DeviceStatColumns.power(status, kind: kind))
                StatColumnView(column: DeviceStatColumns.adapter(status))
                StatColumnView(column: DeviceStatColumns.time(status, kind: kind, now: now))
            }
            .padding(.leading, Self.contentIndent)
            .opacity(detailsAreStale ? 0.55 : 1.0)
        }
        .opacity(status.isStale ? 0.45 : 1.0)
    }

    /// Looks `error.localizedKey` (e.g. `"tandem.error.unreachable"`) up in
    /// the String Catalog directly, rather than switching on the case here —
    /// the catalog is the single source of truth for wording, and a case
    /// added to `MonitorError` later only needs a catalog entry, not a
    /// matching Swift `switch`.
    private func localizedErrorText(_ error: MonitorError) -> String {
        String(localized: String.LocalizationValue(error.localizedKey))
    }

    /// Hover text for the overdue glyph: when the phone last answered, how
    /// long ago that was, and the last error if the monitor recorded one.
    private func attentionTooltip(_ status: DeviceStatus) -> String {
        let clock = status.lastSeen.formatted(date: .omitted, time: .shortened)
        let ago = StatusFormatter.shortDuration(now.timeIntervalSince(status.lastSeen))
        let calendar = Calendar.current
        let when: String
        if calendar.isDateInToday(status.lastSeen) {
            when = String(format: String(localized: "Last seen today at %1$@ (%2$@ ago)"), clock, ago)
        } else if calendar.isDateInYesterday(status.lastSeen) {
            when = String(format: String(localized: "Last seen yesterday at %1$@ (%2$@ ago)"), clock, ago)
        } else {
            let day = status.lastSeen.formatted(date: .abbreviated, time: .shortened)
            when = String(format: String(localized: "Last seen %1$@ (%2$@ ago)"), day, ago)
        }
        if let error { return when + "\n" + localizedErrorText(error) }
        return when
    }

    private func headerRow(_ status: DeviceStatus) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(status.reading.name)
                .lineLimit(1)
                .truncationMode(.tail)
            if kind == .iphone, phoneNeedsAttention(status) {
                warningGlyph.help(attentionTooltip(status))
            } else if status.reading.isCharging {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 8)
            Text("\(status.reading.percent) %")
                .monospacedDigit()
                .fontWeight(.semibold)
        }
    }

    /// True once the iPhone's `lastSeen` is older than
    /// `phoneAttentionThreshold` (5 min) — swaps the header's bolt for a
    /// warning glyph, in place of any freshness text.
    private func phoneNeedsAttention(_ status: DeviceStatus) -> Bool {
        now.timeIntervalSince(status.lastSeen) > Self.phoneAttentionThreshold
    }

    private var warningGlyph: some View {
        Image(systemName: "exclamationmark.circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(.orange)
    }

    /// 6 pt bar, colored purely by charge level (red < 20 %, orange < 50 %,
    /// green otherwise). Charging state never changes this color.
    private func levelBar(percent: Int) -> some View {
        let fraction = CGFloat(min(100, max(0, percent))) / 100
        return GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                Capsule()
                    .fill(batteryLevelColor(percent))
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 6)
    }

    private var symbolName: String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        }
    }

    // MARK: - Stat columns
    //
    // The three columns, their wording and their em-dash fallbacks now live in
    // `StatColumns.swift`, because the summary window stacks the same three
    // under its own device headers (`SummaryContentView`) and two copies of
    // "how to print a wattage" is one too many.

    // MARK: - Unknown device

    private var unknownRow: some View {
        HStack(spacing: 6) {
            Image(systemName: kind == .iphone ? "iphone.slash" : symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(notReachableTitle)
                if let error {
                    Text(localizedErrorText(error))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 8)
        }
        .opacity(0.6)
    }

    private var notReachableTitle: String {
        switch kind {
        case .mac: return String(localized: "Mac not reachable")
        case .iphone: return String(localized: "iPhone not reachable")
        }
    }
}
