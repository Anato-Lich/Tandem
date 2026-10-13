import Foundation

/// The two words a duration is spelled with. A table rather than a
/// `DateComponentsFormatter`: `.abbreviated` drops the zero padding the
/// popover's columns are aligned on ("2 ч 8 мин", not "2 ч 08 мин") and
/// hyphenates some languages' minutes, and the widget's lines have no room to
/// grow. Only the unit is translated — the number stays a number, and W, mAh,
/// °C and Wh are never translated at all.
public struct DurationUnits: Sendable, Equatable {
    public let hour: String
    public let minute: String

    public init(hour: String, minute: String) {
        self.hour = hour
        self.minute = minute
    }

    public static let english = DurationUnits(hour: "h", minute: "min")
    public static let russian = DurationUnits(hour: "ч", minute: "мин")

    /// The app ships en + ru (TandemApp/README.md, "Localization scope");
    /// anything else falls back to English, the development language.
    public static func forLanguage(_ code: String) -> DurationUnits {
        code.lowercased().hasPrefix("ru") ? .russian : .english
    }

    /// Resolved once from the host bundle, so it follows the language the user
    /// actually sees: `Tandem.app` and the widget extension both carry a
    /// String Catalog with en + ru, while `tandemctl` is a bare executable with
    /// no localizations at all and therefore stays English.
    public static let current = forLanguage(Bundle.main.preferredLocalizations.first ?? "en")
}

/// One-line human renderings, shared by `tandemctl` and (later) the menu bar.
public enum StatusFormatter {

    /// `MacBook Pro  84 %  discharging  −32.6 W  7:26 left`
    /// `MacBook Pro  90 %  plugged  13.3/140 W  system 13.3 W`
    /// `iPhone  28 %  charging  13.0/15 W  system 1.9 W  80 % in 53 min  wifi`
    ///
    /// `tandemctl` output only, and deliberately English throughout: it is a
    /// diagnostic line that gets pasted into notes and issues, and its words
    /// ("charging", "partial", "stale") are not in any catalog either. Hence
    /// the explicit `.english` units below rather than the localised default.
    public static func line(for status: DeviceStatus, now: Date = Date()) -> String {
        let reading = status.reading
        var parts: [String] = [reading.name, "\(reading.percent) %", stateWord(reading)]

        // Plugged in, charging or not: what the adapter is supplying out of what
        // it could supply, and what the machine itself is drawing. On battery
        // there is one number, and it is negative.
        if reading.externalConnected {
            if let adapter = adapterText(status) { parts.append(adapter) }
            if let load = reading.systemLoadW {
                parts.append(String(format: "system %.1f W", load))
            }
        } else if let load = reading.systemLoadW {
            parts.append(String(format: "\u{2212}%.1f W", load))
        } else if !reading.isCharging, !isUnknownPower(status) {
            parts.append(String(format: "%@%.1f W", reading.batteryPowerW < 0 ? "\u{2212}" : "", abs(reading.batteryPowerW)))
        }

        if let eta = status.etaTo80 {
            parts.append("\(status.chargeTarget) % in \(shortDuration(eta, units: .english))")
        }
        if let empty = status.timeToEmpty {
            parts.append("\(clockDuration(empty)) left")
        }
        if reading.transport != .local {
            parts.append(reading.transport.rawValue)
        }
        // The degraded tier: percent and charging are current, everything to
        // their left came from a full read `detailAge` seconds ago.
        if reading.isPartial {
            parts.append("partial")
            if let age = status.detailAge {
                parts.append("detail \(compactAge(age)) ago")
            }
        }
        if status.isStale {
            parts.append("(stale, \(shortDuration(now.timeIntervalSince(status.lastSeen), units: .english)) old)")
        }
        return parts.joined(separator: "  ")
    }

    /// `13.3/140 W` — what is coming out of the adapter over what the adapter is
    /// rated for. Either half falls away when it is unknown; `nil` when both are
    /// (a partial reading, or a device plugged into something that reports
    /// neither).
    ///
    /// `systemPowerInW` is the number to use even when nothing is charging: a
    /// Mac sitting on a brick has `Amperage == 0`, so battery current says only
    /// that the pack is idle, never what the wall is doing.
    static func adapterText(_ status: DeviceStatus) -> String? {
        let reading = status.reading
        let into = reading.systemPowerInW ?? status.chargingWatts
        let rated = (reading.adapterWatts ?? 0) > 0 ? reading.adapterWatts : nil
        switch (into, rated) {
        case let (into?, rated?): return String(format: "%.1f/%d W", into, rated)
        case let (into?, nil): return String(format: "%.1f W", into)
        case let (nil, rated?): return "\(rated) W"
        case (nil, nil): return nil
        }
    }

    /// A partial reading with no full reading behind it knows no power at all,
    /// and `0` there means *unknown*, not "no current is flowing" (NOTES.md
    /// §13.2). Printing `0.0 W` would be a lie, so the column is left out.
    static func isUnknownPower(_ status: DeviceStatus) -> Bool {
        status.reading.isPartial
            && status.reading.batteryPowerW == 0
            && status.chargingWatts == nil
    }

    static func stateWord(_ reading: BatteryReading) -> String {
        if reading.fullyCharged { return "full" }
        if reading.isCharging { return "charging" }
        if reading.externalConnected { return "plugged" }
        return "discharging"
    }

    /// `53 min`, `2 h 05 min` — `53 мин`, `2 ч 05 мин` in Russian. The shape is
    /// identical in every language (number, space, unit; the hour form keeps
    /// its zero padding) so the popover's columns and the widget's lines stay
    /// the width they were laid out for.
    public static func shortDuration(_ seconds: TimeInterval, units: DurationUnits = .current) -> String {
        let total = Int(seconds.rounded())
        guard total >= 0 else { return "--" }
        let minutes = (total + 30) / 60
        if minutes < 60 { return "\(minutes) \(units.minute)" }
        return String(format: "%d %@ %02d %@", minutes / 60, units.hour, minutes % 60, units.minute)
    }

    /// `45s`, `3m`, `1h 02m` — the compact form used for ages rather than for
    /// countdowns. Not localised: it appears only in `tandemctl`'s status line
    /// and in the monitor's diagnostic strings, never in the UI, which shows
    /// its own staleness age through the widget's catalog instead.
    public static func compactAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh %02dm", minutes / 60, minutes % 60)
    }

    /// `7:26` — pure digits, so there is nothing in it to translate; the
    /// widget and the popover show the same string in every language.
    public static func clockDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        return String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
