import SwiftUI
import Charts
import BatteryCore

/// One device as the summary window draws it: the live reading for the header
/// (so the percent matches the popover and the menu bar to the second), and the
/// recorded history for everything underneath (`HistoryStore` is the only place
/// a last charge session or a 24 h chart can come from — NOTES.md §15).
///
/// Deliberately plain data with no store, no model and no clock in it, so the
/// whole window can be rendered offscreen from synthetic values
/// (`tools/render-summary.swift`).
struct SummaryDevice: Identifiable, Equatable {
    var kind: DeviceKind
    var status: DeviceStatus?
    var history: DeviceHistory?
    var trend: CapacityTrend?

    var id: String { kind.rawValue }

    /// The live reading wins; a device that has gone quiet still has whatever
    /// the store last recorded.
    var percent: Int? { status?.reading.percent ?? history?.percent }
    var isCharging: Bool { status?.reading.isCharging ?? history?.isCharging ?? false }

    var name: String {
        if let name = status?.reading.name, !name.isEmpty { return name }
        if let name = history?.name, !name.isEmpty { return name }
        switch kind {
        case .mac: return String(localized: "Mac")
        case .iphone: return String(localized: "iPhone")
        }
    }

    var symbolName: String {
        switch kind {
        case .mac: return "laptopcomputer"
        case .iphone: return "iphone"
        }
    }
}

// MARK: - The window's content

/// The summary window's body, in whichever of the two approved shapes the user
/// picked (`SummaryLayout`, the popover's "Summary layout" submenu).
///
/// Both are built from the same `SummaryPresentation`, so the two layouts can
/// disagree about how much room a number gets but never about what it says.
struct SummaryContentView: View {
    let devices: [SummaryDevice]
    var now: Date = Date()
    var layout: SummaryLayout = .columns
    /// The device the window was opened for, if any.
    var highlight: DeviceKind?
    /// Bumped by every fresh request, so clicking the same tile twice flashes
    /// the same column twice (`SummaryRequest.token`).
    var highlightToken: Int = 0

    @State private var highlighted: DeviceKind?
    /// Which tab the tabbed layout is on. Persisted, because a plain
    /// `tandem://summary` (the small widget, the popover's menu) names no
    /// device and should land where the user last was.
    @AppStorage("summaryTab") private var selectedTab = DeviceKind.mac.rawValue

    /// How long the tint stays up before it fades out.
    private static let highlightDuration: TimeInterval = 1.5

    var body: some View {
        Group {
            switch layout {
            case .columns:
                SummaryColumnsBody(devices: devices, now: now, highlighted: highlighted)
            case .tabs:
                SummaryTabsBody(
                    devices: devices,
                    now: now,
                    selection: DeviceKind(rawValue: selectedTab) ?? .mac,
                    onSelect: { selectedTab = $0.rawValue }
                )
            }
        }
        .task(id: highlightToken) { await respondToRequest() }
    }

    /// A request naming a device means two different things in the two layouts:
    /// the two-column one tints that column for a moment, the tabbed one simply
    /// switches to it. A request naming none leaves the tab where it was.
    private func respondToRequest() async {
        guard let highlight else { return }
        guard layout == .columns else {
            selectedTab = highlight.rawValue
            return
        }
        withAnimation(.easeOut(duration: 0.18)) { highlighted = highlight }
        try? await Task.sleep(for: .seconds(Self.highlightDuration))
        guard !Task.isCancelled else { return }
        withAnimation(.easeInOut(duration: 0.45)) { highlighted = nil }
    }
}

// MARK: - What one device says

/// Every string either layout prints about one device, worked out once.
///
/// The live `DeviceStatus` answers "what is happening now" (the chips, the
/// hero subtitle) and `DeviceHistory` answers everything else. Every property
/// is optional wherever the number behind it can be unknown: the rule for this
/// window is that a row with nothing behind it is left out, never drawn as
/// `0 %`, `0.0 W` or a dash (a placeholder in a health readout reads as an
/// answer).
struct SummaryPresentation {
    let device: SummaryDevice
    var now: Date = Date()

    var kind: DeviceKind { device.kind }
    var name: String { device.name }
    var percent: Int? { device.percent }
    var isCharging: Bool { device.isCharging }
    var levelColor: Color { summaryLevelColor(device.percent) }
    var percentText: String { device.percent.map { "\($0) %" } ?? StatColumn.emDash }

    private var status: DeviceStatus? { device.status }
    private var history: DeviceHistory? { device.history }

    // MARK: Chips

    struct Chip {
        var symbolName: String?
        var text: String
        var tint: Color?
        var neutralForeground: Color = SummaryPalette.ink
    }

    /// `36/45 W` in amber while charging, `powerplug 32/140 W` on a charger
    /// that is only carrying the machine, `−13 W` on battery. An iPhone on
    /// battery reports nothing measurable, so it gets no chip at all — the same
    /// rule the widget's power line follows.
    var powerChip: Chip? {
        guard let status else { return nil }
        let reading = status.reading

        if reading.externalConnected {
            let column = DeviceStatColumns.adapter(status)
            guard column.value != StatColumn.emDash else { return nil }
            return Chip(
                symbolName: reading.isCharging ? "bolt.fill" : "powerplug",
                text: column.value,
                tint: reading.isCharging ? SummaryPalette.amber : nil,
                neutralForeground: SummaryPalette.muted
            )
        }

        guard kind == .mac else { return nil }
        let column = DeviceStatColumns.power(status, kind: kind)
        guard column.value != StatColumn.emDash else { return nil }
        return Chip(text: column.value, neutralForeground: SummaryPalette.muted)
    }

    /// `charged`, `80 % · 14 min`, `4:19` — exactly one of them, or nothing at
    /// all when the device has never been seen.
    var statusChip: Chip? {
        guard let text = statusText else { return nil }
        return Chip(symbolName: "clock", text: text)
    }

    /// The status chip's words, also the tail of the tabbed layout's subtitle.
    var statusText: String? {
        guard let status else { return nil }
        let reading = status.reading

        if reading.isCharging {
            guard let remaining = status.timeTo80(now: now) else { return String(localized: "charging") }
            guard remaining >= 30 else { return String(localized: "charged") }
            // Concatenated rather than interpolated: a localisation key
            // carrying a bare `%` next to a placeholder is a `String(format:)`
            // accident waiting to happen (the same reason `80 % at` is split).
            let lead = status.chargeTarget < 100 ? String(localized: "80 % ·") : String(localized: "100 % ·")
            return "\(lead) \(StatusFormatter.shortDuration(remaining))"
        }
        if reading.externalConnected {
            return (reading.fullyCharged || reading.percent >= 80)
                ? String(localized: "charged") : String(localized: "on hold")
        }
        guard let empty = status.timeToEmpty else { return nil }
        return StatusFormatter.clockDuration(empty)
    }

    /// The tabbed layout's one line under the big percent:
    /// `Charged · on 140 W adapter`, `Charging 36/45 W · 80 % in 14 min`,
    /// `On battery · 4:19`.
    var heroSubtitle: String? {
        guard let status else { return nil }
        let reading = status.reading
        var parts: [String] = []

        if reading.isCharging {
            var lead = String(localized: "Charging")
            if let power = powerChip?.text { lead += " \(power)" }
            parts.append(lead)
            if let remaining = status.timeTo80(now: now), remaining >= 30 {
                let lead = status.chargeTarget < 100 ? String(localized: "80 % in") : String(localized: "100 % in")
                parts.append("\(lead) \(StatusFormatter.shortDuration(remaining))")
            } else {
                parts.append(String(localized: "charged"))
            }
        } else if reading.externalConnected {
            parts.append((reading.fullyCharged || reading.percent >= 80)
                         ? String(localized: "Charged") : String(localized: "on hold"))
            if let rated = reading.adapterWatts, rated > 0 {
                parts.append(String(format: String(localized: "on %@ adapter"), "\(rated) W"))
            }
        } else {
            parts.append(String(localized: "On battery"))
            if let empty = status.timeToEmpty {
                parts.append(StatusFormatter.clockDuration(empty))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Battery

    var healthValue: String? { history?.health.map { "\($0.percent) %" } }
    var healthCapacity: String? { history?.health.map { "\($0.rawMaxMAh) / \($0.designMAh) mAh" } }
    var cyclesValue: String? { history?.cycleCount.map { "\($0)" } }
    var temperatureValue: String? { history?.temperatureC.map { String(format: "%.1f °C", $0) } }

    /// `normal` under 40 °C, `warm` at or above it. Not a warning — a pack that
    /// has just taken 96 W is *supposed* to be warm — so there is no red state.
    var temperatureNote: String? {
        guard let celsius = history?.temperatureC else { return nil }
        return celsius < 40 ? String(localized: "normal") : String(localized: "warm")
    }

    /// What the machine itself is drawing, signed the way the popover signs it
    /// (`−13 W` on battery). `nil` for anything that reports no telemetry.
    var systemLoadValue: String? {
        guard let status else { return nil }
        let column = DeviceStatColumns.power(status, kind: kind)
        return column.value == StatColumn.emDash ? nil : column.value
    }

    var systemLoadSeries: [Double] { history?.systemLoadSeries ?? [] }

    /// The tabbed layout's health sub-line: `8389 / 8579 mAh · 33 cycles`.
    var healthSub: String? {
        var parts: [String] = []
        if let capacity = healthCapacity { parts.append(capacity) }
        if let cycles = history?.cycleCount { parts.append(String(localized: "\(cycles) cycles")) }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Last charge

    var lastSession: ChargeSession? { history?.lastSession }

    /// `Yesterday 22:04 → 02:31`, `Today 17:26 → now`.
    var lastChargeRange: String? {
        lastSession.map { SummaryFormat.sessionRange($0, now: now) }
    }

    /// `24 → 100 %`.
    var lastChargeValue: String? {
        lastSession.map { "\($0.fromPercent) \(SummaryFormat.arrow) \($0.toPercent) %" }
    }

    /// `avg 14 W · peak 96 W · 80 % in 2 h 08 min`, with every part that has no
    /// number behind it simply absent.
    var lastChargeDetail: String? {
        guard let session = lastSession else { return nil }
        var parts: [String] = []
        if let average = SummaryFormat.averageWatts(session) {
            parts.append("\(String(localized: "avg")) \(SummaryFormat.watts(average))")
        }
        if let peak = session.peakWatts {
            parts.append("\(String(localized: "peak")) \(SummaryFormat.watts(peak))")
        }
        if let to80 = session.timeTo80, to80 >= 60 {
            parts.append("\(String(localized: "80 % in")) \(StatusFormatter.shortDuration(to80))")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// The tabbed layout puts the *when* in the sub-line instead:
    /// `Yesterday 22:04 → 02:31 · 80 % in 2 h 08 min`.
    var lastChargeWhen: String? {
        guard let session = lastSession, let range = lastChargeRange else { return nil }
        guard let to80 = session.timeTo80, to80 >= 60 else { return range }
        return "\(range) \u{00B7} \(String(localized: "80 % in")) \(StatusFormatter.shortDuration(to80))"
    }

    static let noSessions = String(localized: "No charge sessions yet")

    // MARK: Today

    var today: DailyStat? { history?.today }

    var todayRange: String? {
        today.map { "\($0.minPercent)\u{2013}\($0.maxPercent) %" }
    }

    var todayOnCharger: String? {
        today.map { StatusFormatter.shortDuration($0.minutesOnCharger * 60) }
    }

    var todayCycles: String? {
        today.map { String(format: "%.2f", $0.cyclesEstimate) }
    }

    var todayDraw: String? {
        today?.averageDrawWatts.map { String(format: "%.1f W", $0) }
    }

    /// `on charger · 0.90 cycles · draw 11.3 W`.
    var todaySub: String? {
        var parts: [String] = [String(localized: "on charger")]
        if let cycles = todayCycles {
            parts.append(String(format: String(localized: "%@ cycles"), cycles))
        }
        if let draw = todayDraw {
            parts.append("\(String(localized: "draw")) \(draw)")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: The chart

    /// The 48 half-hour bins the chart draws (`DeviceHistory.bins24h`). The
    /// older `series` is still in the summary file — the widget reads it — but
    /// this window no longer draws from it: a bin is a fixed slot on the clock,
    /// and that is what the approved chart needs (see `SummaryChartCard`).
    var bins: [HistoryBin] { history?.bins24h ?? [] }

    /// Two bins with a percent in them is the floor for a chart; below it the
    /// card draws its axes and one sentence.
    var hasChart: Bool { bins.filter { $0.percent != nil }.count >= 2 }
}

// MARK: - Wording

/// Every sentence-shaped string the summary window prints, in one place.
enum SummaryFormat {

    static let arrow = "\u{2192}"

    /// `Today 13:13 → 17:13`, `Yesterday 22:04 → 07:31`, `7 Sep 13:13 → now`.
    static func sessionRange(_ session: ChargeSession, now: Date = Date(), calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDateInToday(session.start) {
            day = String(localized: "Today")
        } else if calendar.isDateInYesterday(session.start) {
            day = String(localized: "Yesterday")
        } else {
            day = session.start.formatted(.dateTime.day().month(.abbreviated))
        }
        let end = session.end.map { clock($0) } ?? String(localized: "now")
        return "\(day) \(clock(session.start)) \(arrow) \(end)"
    }

    /// "avg" is `energyWh / duration` wherever both are known — a time-weighted
    /// figure, which with the skip rule's deliberately uneven samples is the
    /// defensible one (NOTES.md §15.7) — and the session's plain mean only when
    /// it is not.
    static func averageWatts(_ session: ChargeSession) -> Double? {
        if let energy = session.energyWh, let duration = session.duration, duration >= 60 {
            return energy / (duration / 3600)
        }
        return session.averageWatts
    }

    /// `14 W`, `12.6 W`. One decimal, dropped when it is a zero: a session that
    /// averaged 14.0 W averaged 14 W, and the extra glyph buys nothing on a
    /// 10.5 pt sub-line.
    static func watts(_ value: Double) -> String {
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) W"
        }
        return String(format: "%.1f W", rounded)
    }

    /// `13:13` — locale's own clock, so a 12-hour locale gets `1:13 PM`.
    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour().minute())
    }
}
