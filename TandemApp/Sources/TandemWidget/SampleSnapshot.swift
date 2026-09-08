import Foundation

/// The 32 % / 38 % pair the widget gallery shows before it has any real data:
/// a MacBook on a 140 W brick pulling 136 W and 27 minutes from 80 %, an iPhone
/// on battery with 13:21 left.
///
/// These are the approved mock-up's own numbers
/// (`docs/design/widget/MediumA.dc.html`), so the gallery preview and the
/// picture the design was signed off on are the same picture — and
/// `SampleHistory`'s day ends on exactly these two levels, so the tile and the
/// strip under it never disagree about the same battery.
enum SampleSnapshot {

    static func make(now: Date = Date()) -> TandemSnapshot {
        TandemSnapshot(
            generatedAt: now,
            mac: DeviceStatus(
                reading: reading(
                    kind: .mac,
                    name: "MacBook Pro",
                    percent: SampleHistory.macPercent,
                    isCharging: true,
                    batteryPowerW: 96,
                    systemPowerInW: 136,
                    adapterWatts: 140,
                    now: now
                ),
                etaTo80: 27 * 60,
                chargingWatts: 136,
                lastSeen: now
            ),
            phone: DeviceStatus(
                reading: reading(
                    kind: .iphone,
                    name: "iPhone",
                    percent: SampleHistory.phonePercent,
                    isCharging: false,
                    batteryPowerW: -1.8,
                    systemPowerInW: nil,
                    adapterWatts: nil,
                    now: now
                ),
                timeToEmpty: 13 * 3600 + 21 * 60,
                lastSeen: now
            )
        )
    }

    private static func reading(
        kind: DeviceKind,
        name: String,
        percent: Int,
        isCharging: Bool,
        batteryPowerW: Double,
        systemPowerInW: Double?,
        adapterWatts: Int?,
        now: Date
    ) -> BatteryReading {
        BatteryReading(
            deviceID: "sample-\(kind.rawValue)",
            kind: kind,
            name: name,
            percent: percent,
            isCharging: isCharging,
            externalConnected: isCharging,
            fullyCharged: false,
            rawCurrentMAh: 0,
            rawMaxMAh: 0,
            designMAh: 0,
            voltageMV: 0,
            instantAmperageMA: 0,
            batteryPowerW: batteryPowerW,
            systemPowerInW: systemPowerInW,
            adapterWatts: adapterWatts,
            adapterDescription: nil,
            temperatureC: 0,
            cycleCount: 0,
            reportedTimeRemainingMinutes: nil,
            avgTimeToEmptyMinutes: nil,
            timestamp: now,
            transport: kind == .mac ? .local : .wifi
        )
    }
}
