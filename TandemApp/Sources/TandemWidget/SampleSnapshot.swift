import Foundation

/// The 71 % / 64 % pair the widget gallery shows before it has any real data:
/// a Mac on battery with 4:19 left, an iPhone charging at 16.5 W off a 45 W
/// adapter, 14 minutes from 80 %. Chosen to match the approved mock-ups so the
/// gallery preview and the live widget are the same picture.
enum SampleSnapshot {

    static func make(now: Date = Date()) -> TandemSnapshot {
        TandemSnapshot(
            generatedAt: now,
            mac: DeviceStatus(
                reading: reading(
                    kind: .mac,
                    name: "MacBook Pro",
                    percent: 71,
                    isCharging: false,
                    batteryPowerW: -13.4,
                    adapterWatts: nil,
                    now: now
                ),
                timeToEmpty: 4 * 3600 + 19 * 60,
                lastSeen: now
            ),
            phone: DeviceStatus(
                reading: reading(
                    kind: .iphone,
                    name: "iPhone",
                    percent: 64,
                    isCharging: true,
                    batteryPowerW: 16.5,
                    adapterWatts: 45,
                    now: now
                ),
                etaTo80: 14 * 60,
                chargingWatts: 16.5,
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
            systemPowerInW: nil,
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
