import SwiftUI
import BatteryCore

/// One telemetry column: a value over a caption, and nothing else.
///
/// This is the popover's approved unit of information (`DeviceRowView`), lifted
/// out of it so the summary window can stack the very same columns under its
/// device headers rather than growing a second, slightly different way of
/// printing a wattage.
struct StatColumn {
    let value: String
    let caption: String
    var color: Color = .primary
    var showsBolt: Bool = false

    static let emDash = "\u{2014}"
    static let minus = "\u{2212}"

    static func unknown(_ caption: String) -> StatColumn {
        StatColumn(value: emDash, caption: caption, color: .secondary)
    }
}

/// The value/caption pair as both the popover row and the summary window draw
/// it: 12 pt semibold monospaced digits over a 9.5 pt secondary caption, with an
/// optional orange bolt in front of the value while power is flowing in.
struct StatColumnView: View {
    let column: StatColumn

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                if column.showsBolt {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
                Text(column.value)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(column.color)
            }
            Text(column.caption)
                .font(.system(size: 9.5))
                .tracking(0.2)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// The three columns a live `DeviceStatus` produces — power, adapter, time —
/// worked out in one place so the popover row and the summary header can never
/// disagree about what a reading says.
///
/// A partial (degraded-tier) reading only carries percent/isCharging/
/// externalConnected/fullyCharged; every other field is 0/nil because it is
/// unknown (NOTES.md §13.2). Every column below falls back to an em dash when
/// its optional is nil, so a baseless partial reading never prints "0.0 W".
enum DeviceStatColumns {

    /// Column 1: what the machine itself is drawing right now — `SystemLoad`
    /// out of `PowerTelemetryData`, captioned "system".
    ///
    /// This is the column that used to read `draw 0 W` while the Mac sat on a
    /// charger: battery current is `0` there because the pack is neither
    /// filling nor emptying, which says nothing at all about what the machine
    /// is consuming. `SystemLoad` does, and it is reported plugged or not.
    ///
    /// Plugged in it is a plain `13 W`; on battery it is `−13 W`, falling back
    /// to the old Amperage × Voltage figure when the device reports no
    /// telemetry. An iPhone on battery still shows nothing, per the brief.
    static func power(_ status: DeviceStatus, kind: DeviceKind) -> StatColumn {
        let reading = status.reading
        let caption = String(localized: "system")

        if reading.externalConnected {
            guard let load = reading.systemLoadW else { return .unknown(caption) }
            return StatColumn(value: wholeWatts(load), caption: caption)
        }

        switch kind {
        case .mac:
            // A partial reading's 0 W is unknown, not idle (NOTES.md §13.2).
            if let load = reading.systemLoadW {
                return StatColumn(value: wholeWatts(-load), caption: caption)
            }
            guard !reading.isPartial else { return .unknown(caption) }
            return StatColumn(value: wholeWatts(-abs(reading.batteryPowerW)), caption: caption)
        case .iphone:
            return .unknown(caption)
        }
    }

    /// Column 2: the adapter — `13/140 W`, what it is supplying over what it is
    /// rated for, with the orange bolt only while the pack is actually being
    /// charged. An em dash when nothing is plugged in.
    ///
    /// Plugged in and not charging is a real reading, not a blank: the wall is
    /// still carrying the whole machine. `systemPowerInW` is what says so; the
    /// estimator's `chargingWatts` is the fallback, since it exists only while
    /// charging.
    static func adapter(_ status: DeviceStatus) -> StatColumn {
        let reading = status.reading
        let caption = String(localized: "adapter")
        guard reading.externalConnected else { return .unknown(caption) }

        let into = reading.systemPowerInW ?? status.chargingWatts
        let rated = (reading.adapterWatts ?? 0) > 0 ? reading.adapterWatts : nil
        let text: String
        switch (into, rated) {
        case let (into?, rated?): text = "\(Int(into.rounded()))/\(rated) W"
        case let (into?, nil): text = wholeWatts(into)
        case let (nil, rated?): text = "\(rated) W"
        case (nil, nil): return .unknown(caption)
        }
        return StatColumn(
            value: text,
            caption: caption,
            color: reading.isCharging ? .orange : .primary,
            showsBolt: reading.isCharging
        )
    }

    /// Column 3: charging → time to 80 %, then to 100 % (counted down from the absolute
    /// deadline `etaTo80At`, not from the ETA as it stood at the last poll);
    /// discharging → time left, `h:mm` on the Mac and `h min` on the iPhone.
    static func time(_ status: DeviceStatus, kind: DeviceKind, now: Date) -> StatColumn {
        let reading = status.reading

        if reading.isCharging {
            let caption = status.chargeTarget < 100 ? String(localized: "to 80 %") : String(localized: "to 100 %")
            guard let remaining = status.timeTo80(now: now) else { return .unknown(caption) }
            // Past the deadline (or within half a minute of it) the target is
            // met; a "0 min", or worse a negative, would be a countdown lying
            // about what it is counting.
            guard remaining >= 30 else {
                return StatColumn(value: String(localized: "charged"), caption: caption, color: .secondary)
            }
            return StatColumn(value: StatusFormatter.shortDuration(remaining), caption: caption)
        }

        // Plugged in but not charging: the battery is either full or the
        // system is holding it (optimised charging); nothing counts down.
        if reading.externalConnected {
            let caption = String(localized: "status")
            let value = (reading.fullyCharged || reading.percent >= 80)
                ? String(localized: "charged") : String(localized: "on hold")
            return StatColumn(value: value, caption: caption, color: .secondary)
        }

        let caption = String(localized: "left")
        guard let empty = status.timeToEmpty else { return .unknown(caption) }
        switch kind {
        case .mac:
            return StatColumn(value: StatusFormatter.clockDuration(empty), caption: caption)
        case .iphone:
            return StatColumn(value: StatusFormatter.shortDuration(empty), caption: caption)
        }
    }

    /// `13 W`, `−13 W`. Whole watts: a tenth of a watt has never changed
    /// anybody's mind, and these columns sit beside each other at 12 pt.
    static func wholeWatts(_ value: Double) -> String {
        let rounded = Int(abs(value).rounded())
        return "\(value < 0 && rounded > 0 ? StatColumn.minus : "")\(rounded) W"
    }

    static func watts(_ value: Double) -> String {
        String(format: "%@%.1f W", value < 0 ? StatColumn.minus : "", abs(value))
    }
}

/// Level → colour, the one rule the whole app draws by: green, and red under
/// 20 %. Two bands, not three. Orange is reserved for charging — the bolt, the
/// amber watts, the amber bars of a day strip — and an orange band at 49 %
/// collided with it: half the batteries in the app looked plugged in.
func batteryLevelColor(_ percent: Int?) -> Color {
    guard let percent else { return .secondary }
    return percent < lowBatteryLevel ? .red : .green
}

/// Below this a level reads as red, in the popover, the widget and the summary
/// window alike.
let lowBatteryLevel = 20
