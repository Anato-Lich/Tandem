import Foundation
import SwiftUI

/// Everything both widget sizes need about one device, worked out once so the
/// small and medium layouts can never drift apart in wording or colour.
struct DevicePresentation {

    let kind: DeviceKind
    /// `nil` when the device has never been seen. Nothing renders a 0 % for a
    /// device it has no reading for — the tile shows an em dash and a bare ring
    /// track instead, because "0 %" is a claim and this is an absence.
    let percent: Int?
    let isCharging: Bool
    /// The line under the percent in the small widget.
    let timeLine: String

    // MARK: The medium tile's two slots
    //
    // Beside the ring: the power line, and nothing else.
    // Under the ring, right of the percent: exactly one status, whatever the
    // device is doing.

    /// Beside the ring. One compact "into / available" line:
    /// `62/140 W` charging off a 140 W brick, `13/140 W` plugged in and not
    /// charging (the wall is still carrying the machine — `SystemPowerIn`),
    /// `140W` (with `showsPlugGlyph`) when only the brick's rating is known,
    /// `−13W` on battery. Nil for an iPhone on battery, whose discharge
    /// wattage is deliberately never shown, and nil whenever there is no
    /// wattage to report.
    let powerText: String?
    /// Prefix the top line with a `powerplug` glyph: the plugged-in-but-not-
    /// charging case, where the wall is carrying the machine and putting
    /// nothing into the pack. Always paired with `topKind == .plugged`.
    let showsPlugGlyph: Bool

    /// Bottom row, right of the percent, and always exactly one of:
    /// `80 % · 14 min` (time to the 80 % target while charging), `charged` /
    /// `on hold` (plugged in, not charging), `4:19` (time to empty on battery),
    /// `14:32` (the moment a silent device was last heard from).
    /// Nil only for a device with no reading at all.
    let statusText: String?

    // MARK: The one line beside the ring

    /// How the top line is drawn, which is the whole of what it means.
    enum TopLineKind {
        /// Amber and semibold: watts actually going into the pack.
        case charging
        /// Blue and semibold behind a `powerplug` glyph: on the wall, holding.
        /// The number is what the wall is carrying, not what the pack is
        /// taking, and the colour is the one the `mains` bars are drawn in.
        case plugged
        /// Secondary: a discharge figure, "on battery", "no contact
        /// 14:32", "no data". Nothing here is a flow of power.
        case plain
    }

    /// The line beside the ring, resolved. Nil only when there is genuinely
    /// nothing to say; every state in the approved matrix says something.
    let topText: String?
    /// Narrower spellings of the same line, widest first, for the rare case
    /// where even the tight form will not fit beside the ring. The tile writes
    /// wattage closed up (`132/140W`, the way Apple names its own bricks)
    /// because the space before the unit was the couple of points that made a
    /// three-digit pair overflow half a medium widget.
    let topTextFallbacks: [String]
    let topKind: TopLineKind

    /// `DeviceStatus.isSilent(now:)`: we have been *trying and failing* to read
    /// this device for over ten minutes. The tile drops to 45 % and its ring
    /// takes an exclamation mark instead of the bolt.
    ///
    /// Not staleness. The phone is polled every 2–5 minutes when somebody is
    /// looking and not at all while the display sleeps (NOTES.md §14), so a
    /// reading being twenty minutes old is the design working, not a fault, and
    /// a badge keyed to `lastSeen` age was lit almost permanently. The rule and
    /// its two thresholds live on `DeviceStatus` (`silenceWindow`,
    /// `silenceAttempts`) so the widget and the popover cannot disagree.
    let isSilent: Bool

    /// When the snapshot last heard from the device. Nil for a device never
    /// seen at all. Never rendered as a fault on its own.
    let lastSeen: Date?

    /// The moment the current run of failures began — what a silent tile writes
    /// in both of its slots ("no contact" over "14:32"). Nil unless we
    /// are failing.
    let unreachableSince: Date?

    static let emDash = "\u{2014}"
    static let minus = "\u{2212}"

    var symbolName: String {
        switch kind {
        case .mac: "laptopcomputer"
        case .iphone: "iphone"
        }
    }

    /// Ring colour is a pure function of the level: green, and red below
    /// 20 %. Two bands, not three — orange is reserved for charging (the bolt
    /// badge, the amber watts, the amber bars), and a ring that went orange at
    /// 49 % made every half-empty battery look like it was plugged in.
    var levelColor: Color {
        guard let percent else { return .secondary }
        return percent < Self.lowLevel ? .red : .green
    }

    /// Below this the level reads as red, everywhere in the app.
    static let lowLevel = 20

    var percentText: String { percent.map { "\($0) %" } ?? Self.emDash }

    /// A device we have been failing to reach: dimmed, and badged with a
    /// warning instead of the charging bolt.
    var showsSilentBadge: Bool { isSilent && percent != nil }

    var dimming: Double { isSilent ? 0.45 : 1.0 }

    // MARK: - Building

    init(kind: DeviceKind, status: DeviceStatus?, now: Date) {
        self.kind = kind

        guard let status else {
            // Never seen. An empty ring track, an em dash, "no data" — and no
            // badge, because a device that has never reported is not a device
            // that has stopped reporting.
            percent = nil
            isCharging = false
            timeLine = Self.emDash
            powerText = nil
            showsPlugGlyph = false
            statusText = nil
            isSilent = true
            lastSeen = nil
            unreachableSince = nil
            topText = Self.noDataLabel
            topTextFallbacks = []
            topKind = .plain
            return
        }

        let reading = status.reading
        percent = reading.percent
        isCharging = reading.isCharging

        // The one question that decides the whole tile: are we failing, or is
        // this simply the newest reading anybody has needed?
        let silent = status.isSilent(now: now)
        isSilent = silent
        lastSeen = status.lastSeen
        unreachableSince = status.unreachableSince
        // How long the silence has run, not how old the reading is.
        let silentAt = status.unreachableSince ?? status.lastSeen
        let silence = now.timeIntervalSince(silentAt)

        timeLine = Self.timeLine(status: status, now: now, age: silent ? silence : nil)

        let power = Self.powerLine(kind: kind, status: status)?.full
        let powerFallbacks = Self.powerLine(kind: kind, status: status)?.fallbacks ?? []
        powerText = power
        let plugged = reading.externalConnected && !reading.isCharging
        showsPlugGlyph = plugged && power != nil

        // The top line, one state at a time, in the order of the approved
        // matrix (docs/design/widget/StatesMac, StatesPhone).
        if silent {
            topText = Self.noContactLabel
            topTextFallbacks = []
            topKind = .plain
        } else if reading.isCharging {
            topText = power
            topTextFallbacks = powerFallbacks
            topKind = power == nil ? .plain : .charging
        } else if plugged {
            topText = power
            topTextFallbacks = powerFallbacks
            topKind = power == nil ? .plain : .plugged
        } else {
            // A Mac says what it is drawing; a phone's discharge wattage is
            // deliberately never shown, and a partial Mac reading has no honest
            // figure either. Both then say what they *are* doing.
            topText = power ?? Self.onBatteryLabel
            topTextFallbacks = []
            topKind = .plain
        }

        // A silent tile's bottom-right is the moment it went quiet, so the two
        // halves of the tile agree: "no contact" over "14:32".
        statusText = silent
            ? Self.clock(silentAt)
            : Self.statusText(status: status, now: now)
    }

    // MARK: - The small widget's one-line summary (unchanged)

    /// Compact by design: no "in"/"через", just the numbers, except for the
    /// three states with nothing numeric to say (see below).
    ///
    /// - Charging: `80 % · 14 min`, or `80 % · —` while the estimator has no
    ///   ETA yet and the pack is still under 80 %. Once the pack has passed
    ///   80 % the "eta to 80" target is moot (`ChargeEstimator` stops
    ///   producing one), so this reads `chargedLabel` instead of a dangling
    ///   em dash.
    /// - Plugged in but not charging: `chargedLabel` once full or at/above
    ///   80 %, otherwise `onHoldLabel`.
    /// - Discharging: `4:19` (h:mm from `timeToEmpty`), `—` only when that is
    ///   unknown.
    ///
    /// A silent device gets the length of the silence appended as `· 12 min`
    /// in every case.
    private static func timeLine(status: DeviceStatus, now: Date, age: TimeInterval?) -> String {
        var text = statusText(status: status, now: now) ?? emDash
        if let age {
            text += " \u{00B7} \(minutesText(age))"
        }
        return text
    }

    // MARK: - The medium tile's slots

    /// Watts as one short string. Whole watts throughout — a tenth of a watt
    /// has never changed anybody's mind, and the tile has better uses for the
    /// width.
    /// The wattage line and, where one exists, a narrower spelling of it.
    private static func powerLine(kind: DeviceKind, status: DeviceStatus) -> (full: String, fallbacks: [String])? {
        let reading = status.reading
        let adapter = (reading.adapterWatts ?? 0) > 0 ? reading.adapterWatts : nil

        // Plugged in, charging or not. Not charging is not "nothing is
        // happening": the adapter is carrying the whole machine, and
        // `SystemPowerIn` is what it is carrying. Battery current is 0 there,
        // which is why this line used to collapse to the brick's rating alone.
        if reading.externalConnected {
            let into = reading.systemPowerInW ?? status.chargingWatts
            switch (into, adapter) {
            case let (into?, adapter?):
                // "13/140 W" — coming out of the wall over what is available.
                // The unit is the first thing to go when the pair runs wide.
                let pair = "\(Int(into.rounded()))/\(adapter)"
                return ("\(pair)W", [pair])
            case let (into?, nil):
                return ("\(Int(into.rounded()))W", [])
            case let (nil, adapter?):
                // Nothing measurable, so the number is what the brick offers
                // rather than what is flowing. An iPhone left on the wire past
                // 100 % is the usual way to see it: "45 W".
                return ("\(adapter)W", [])
            case (nil, nil):
                return nil
            }
        }

        switch kind {
        case .mac:
            // On battery: what the machine is drawing. `SystemLoad` is the
            // real figure; Amperage x Voltage is the fallback.
            if let load = reading.systemLoadW {
                return ("\(minus)\(Int(load.rounded()))W", [])
            }
            // A partial reading carries 0 W, which is a lie, not a reading.
            guard !reading.isPartial else { return nil }
            let watts = reading.batteryPowerW
            let sign = watts < 0 ? minus : ""
            return ("\(sign)\(Int(abs(watts).rounded()))W", [])
        case .iphone:
            // The phone's discharge wattage is deliberately not shown.
            return nil
        }
    }

    /// The one thing the bottom-right slot says, whatever the device is doing.
    private static func statusText(status: DeviceStatus, now: Date) -> String? {
        let reading = status.reading

        if reading.isCharging {
            if reading.fullyCharged || reading.percent >= 80 { return chargedLabel }
            // Counted from the absolute deadline against this entry's date, so
            // the pre-rendered entries of one timeline count down on their own
            // (NOTES.md §14). Once it is up, the target is met — never "0 min",
            // never a negative.
            if let remaining = status.timeTo80(now: now) {
                guard remaining >= 30 else { return chargedLabel }
                return "80 % \u{00B7} \(minutesText(remaining))"
            }
            return "80 % \u{00B7} \(emDash)"
        }

        if reading.externalConnected {
            return (reading.fullyCharged || reading.percent >= 80) ? chargedLabel : onHoldLabel
        }

        // On battery: time to empty, `4:19`.
        return status.timeToEmpty.map { StatusFormatter.clockDuration($0) }
    }

    // MARK: - Localised words

    private static var chargedLabel: String {
        String(localized: "charged", comment: "Widget: fully charged, or plugged in and at/above 80 %, or charging past the 80 % target with no further ETA.")
    }

    private static var onHoldLabel: String {
        String(localized: "on hold", comment: "Widget: plugged in, not charging, below 80 % and not full.")
    }

    /// What a device on battery says when there is no honest wattage to show:
    /// every iPhone (whose discharge wattage is deliberately never published)
    /// and a Mac whose reading came back partial.
    static var onBatteryLabel: String {
        String(localized: "on battery", comment: "Widget: running off the pack, with no wattage to show.")
    }

    /// A device that has never been seen at all.
    static var noDataLabel: String {
        String(localized: "no data", comment: "Widget: this device has never been seen.")
    }

    /// `no contact` — a device we have been failing to reach for longer than
    /// `DeviceStatus.silenceWindow`. The moment it went quiet is the tile's
    /// bottom-right slot, so the top line does not repeat it: "silent since
    /// 14:32" over "14:32" said the same thing twice and was the one string
    /// too wide for half a medium widget.
    static var noContactLabel: String {
        String(localized: "no contact",
               comment: "Widget: the device has stopped answering; the clock time is in the bottom-right slot.")
    }

    /// The locale's own short clock, so a 12-hour locale gets `2:32 PM`.
    static func clock(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// `14 min` / `14 мин`. Only the unit is localised; the number is a number.
    static func minutesText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return "\(minutes) \(String(localized: "min", comment: "Widget time unit, as in \"80 % · 14 min\"."))"
    }
}
