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
    /// `140 W` (with `showsPlugGlyph`) when only the brick's rating is known,
    /// `−13 W` on battery. Nil for an iPhone on battery, whose discharge
    /// wattage is deliberately never shown, and nil whenever there is no
    /// wattage to report.
    let powerText: String?
    /// Prefix `powerText` with a `powerplug` glyph — the plugged-in-but-not-
    /// charging case, where the number is what the adapter *offers* rather than
    /// what is flowing.
    let showsPlugGlyph: Bool

    /// Bottom row, right of the percent, and always exactly one of:
    /// `80 % · 14 min` (time to the 80 % target while charging), `charged` /
    /// `on hold` (plugged in, not charging), `4:19` (time to empty on battery).
    /// Nil only for a device with no reading at all.
    let statusText: String?

    /// `lastSeen` is more than `stalenessWindow` old: dim this device and badge
    /// its ring.
    let isStale: Bool

    /// Older than this and the device is drawn at 45 % with its age appended.
    static let stalenessWindow: TimeInterval = 10 * 60

    static let emDash = "\u{2014}"
    static let minus = "\u{2212}"

    var symbolName: String {
        switch kind {
        case .mac: "laptopcomputer"
        case .iphone: "iphone"
        }
    }

    /// Ring / bar colour is a pure function of the level. Charging never
    /// changes it — that is the bolt's job.
    var levelColor: Color {
        guard let percent else { return .secondary }
        if percent < 20 { return .red }
        if percent < 50 { return .orange }
        return .green
    }

    var percentText: String { percent.map { "\($0) %" } ?? Self.emDash }

    /// A device with a reading that has gone quiet: dimmed, and badged with a
    /// warning instead of the charging bolt.
    var showsStaleBadge: Bool { isStale && percent != nil }

    var dimming: Double { isStale ? 0.45 : 1.0 }

    // MARK: - Building

    init(kind: DeviceKind, status: DeviceStatus?, now: Date) {
        self.kind = kind

        guard let status else {
            percent = nil
            isCharging = false
            timeLine = Self.emDash
            powerText = nil
            showsPlugGlyph = false
            statusText = nil
            isStale = true
            return
        }

        let reading = status.reading
        percent = reading.percent
        isCharging = reading.isCharging

        let age = now.timeIntervalSince(status.lastSeen)
        let stale = age > Self.stalenessWindow
        isStale = stale

        timeLine = Self.timeLine(status: status, now: now, age: stale ? age : nil)

        let power = Self.powerLine(kind: kind, status: status)
        powerText = power?.text
        showsPlugGlyph = power?.plug ?? false

        var line = Self.statusText(status: status, now: now)
        if stale {
            // The age rides on the status line rather than adding a line, so a
            // stale tile has the same shape as a fresh one.
            let ageText = Self.minutesText(age)
            line = line.map { "\($0) \u{00B7} \(ageText)" } ?? ageText
        }
        statusText = line
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
    /// A stale device gets its age appended as `· 12 min` in every case.
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
    private static func powerLine(kind: DeviceKind, status: DeviceStatus) -> (text: String, plug: Bool)? {
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
                return ("\(Int(into.rounded()))/\(adapter) W", false)
            case let (into?, nil):
                return ("\(Int(into.rounded())) W", false)
            case let (nil, adapter?):
                // Nothing measurable, so the number is what the brick offers
                // rather than what is flowing — the plug glyph says which.
                return ("\(adapter) W", true)
            case (nil, nil):
                return nil
            }
        }

        switch kind {
        case .mac:
            // On battery: what the machine is drawing. `SystemLoad` is the
            // real figure; Amperage x Voltage is the fallback.
            if let load = reading.systemLoadW {
                return ("\(minus)\(Int(load.rounded())) W", false)
            }
            // A partial reading carries 0 W, which is a lie, not a reading.
            guard !reading.isPartial else { return nil }
            let watts = reading.batteryPowerW
            let sign = watts < 0 ? minus : ""
            return ("\(sign)\(Int(abs(watts).rounded())) W", false)
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

    /// `14 min` / `14 мин`. Only the unit is localised; the number is a number.
    static func minutesText(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return "\(minutes) \(String(localized: "min", comment: "Widget time unit, as in \"80 % · 14 min\"."))"
    }
}
