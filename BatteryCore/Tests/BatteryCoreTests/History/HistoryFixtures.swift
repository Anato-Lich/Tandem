import Foundation
import Testing
@testable import BatteryCore

/// Synthetic history built on top of the *real* dumps in `Fixtures/`, so the
/// numbers the derivations chew on (mAh, cycle count, temperature, adapter
/// watts) are the ones a device actually reports rather than round invented
/// ones.
enum HistoryFixtures {

    static let macID = "mac-0001"
    static let phoneID = "00001111-000A1B2C3D4E5F60"

    static func macReading(at timestamp: Date = referenceDate) throws -> BatteryReading {
        try BatteryPlistParser.parseMac(
            Fixture.macDischarging.data,
            deviceID: macID,
            name: "MacBook Pro",
            timestamp: timestamp
        )
    }

    static func phoneReading(charging: Bool = true, at timestamp: Date = referenceDate) throws -> BatteryReading {
        try BatteryPlistParser.parseIPhone(
            charging ? Fixture.iphoneChargingWiFi.data : Fixture.iphoneDischargingWiFi.data,
            deviceID: phoneID,
            name: "iPhone",
            transport: .wifi,
            timestamp: timestamp
        )
    }

    static func status(_ reading: BatteryReading, chargingWatts: Double? = nil) -> DeviceStatus {
        DeviceStatus(reading: reading, chargingWatts: chargingWatts, lastSeen: reading.timestamp)
    }

    /// A row shaped like the fixture's phone, with the fields a test wants to
    /// vary handed in.
    static func phoneRow(
        at timestamp: Date,
        percent: Int,
        charging: Bool = true,
        external: Bool = true,
        fullyCharged: Bool = false,
        watts: Double? = 15.0,
        adapterWatts: Int? = 45,
        device: String = phoneID
    ) throws -> HistoryReading {
        var row = HistoryReading(status: status(try phoneReading(at: timestamp)))
        row.device = device
        row.timestamp = timestamp
        row.percent = percent
        row.isCharging = charging
        row.externalConnected = external
        row.fullyCharged = fullyCharged
        row.watts = watts
        row.adapterWatts = adapterWatts
        return row
    }

    /// A snapshot carrying both devices at one instant.
    static func snapshot(
        at timestamp: Date,
        macPercent: Int,
        phonePercent: Int,
        phoneCharging: Bool = true
    ) throws -> TandemSnapshot {
        var mac = try macReading(at: timestamp)
        mac.percent = macPercent
        var phone = try phoneReading(charging: phoneCharging, at: timestamp)
        phone.percent = phonePercent
        phone.isCharging = phoneCharging
        phone.externalConnected = phoneCharging
        return TandemSnapshot(
            generatedAt: timestamp,
            mac: status(mac),
            phone: status(phone, chargingWatts: phoneCharging ? 15.0 : nil)
        )
    }

    /// A fresh directory per test; delete the whole thing to take the `-wal` and
    /// `-shm` sidecars with it.
    static func temporaryDirectory() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandem-history-\(UUID().uuidString)", isDirectory: true)
    }
}
