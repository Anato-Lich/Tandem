import Foundation

/// Which physical machine a reading came from.
public enum DeviceKind: String, Sendable, Codable, Equatable, CaseIterable {
    case mac
    case iphone
}

/// How the reading reached us.
public enum Transport: String, Sendable, Codable, Equatable, CaseIterable {
    /// Read in-process through IOKit (the Mac we run on).
    case local
    /// Read over usbmuxd via a USB cable.
    case usb
    /// Read over usbmuxd via Wi-Fi ("network") lookup.
    case wifi
}

/// A `Bool` that decodes as `false` when its key is missing.
///
/// Only reason this exists: `BatteryReading.viaDirect` was added after snapshots
/// were already being written to disk, and Swift's synthesised `Decodable` does
/// not fall back to a property's default value for an absent key.
@propertyWrapper
public struct DecodesAsFalseWhenAbsent: Sendable, Codable, Equatable {
    public var wrappedValue: Bool

    public init(wrappedValue: Bool) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: any Decoder) throws {
        wrappedValue = try Bool(from: decoder)
    }

    public func encode(to encoder: any Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedDecodingContainer {
    public func decode(
        _ type: DecodesAsFalseWhenAbsent.Type,
        forKey key: Key
    ) throws -> DecodesAsFalseWhenAbsent {
        try decodeIfPresent(DecodesAsFalseWhenAbsent.self, forKey: key)
            ?? DecodesAsFalseWhenAbsent(wrappedValue: false)
    }
}

/// One point-in-time battery sample from a single device.
///
/// All raw units follow the IORegistry conventions: capacities in mAh, voltage
/// in mV, current in mA (signed: positive charging, negative discharging).
public struct BatteryReading: Sendable, Codable, Equatable {
    public var deviceID: String
    public var kind: DeviceKind
    public var name: String
    public var percent: Int
    public var isCharging: Bool
    public var externalConnected: Bool
    public var fullyCharged: Bool
    public var rawCurrentMAh: Int
    public var rawMaxMAh: Int
    public var designMAh: Int
    public var voltageMV: Int
    /// Signed instantaneous current. Positive while charging.
    public var instantAmperageMA: Int
    /// Signed battery power in watts: `+` into the battery, `-` out of it.
    public var batteryPowerW: Double
    /// Power drawn from the wall/adapter, when the device reports it
    /// (`PowerTelemetryData.SystemPowerIn`). `nil` on battery, where the key is
    /// `0` rather than absent.
    public var systemPowerInW: Double?
    /// What the machine itself is consuming right now
    /// (`PowerTelemetryData.SystemLoad`), as a **magnitude** in watts.
    ///
    /// The sign is not portable — the Mac reports `-32554` mW on battery and
    /// `+13307` mW on the adapter, the iPhone reports `+440` mW on battery — so
    /// the parser keeps the magnitude and the UI takes the direction from
    /// `externalConnected`, exactly as it does for `BatteryPower` (NOTES.md §6).
    /// `nil` when the device does not report the key at all.
    public var systemLoadW: Double?
    public var adapterWatts: Int?
    public var adapterDescription: String?
    public var temperatureC: Double
    public var cycleCount: Int
    /// The device's own `TimeRemaining` estimate in minutes, when it looks sane.
    /// Unreliable on iPhone; usable on Mac.
    public var reportedTimeRemainingMinutes: Int?
    /// The device's `AvgTimeToEmpty` in minutes, when it looks sane. This is the
    /// trustworthy discharge estimate on iPhone (`TimeRemaining` is not).
    public var avgTimeToEmptyMinutes: Int?
    public var timestamp: Date
    public var transport: Transport
    /// True when this reading came from `DirectLockdownClient` — a lockdown
    /// session opened straight to the phone's IP, bypassing usbmuxd's Bonjour
    /// device list. `transport` stays `.wifi`, because that is still the wire.
    ///
    /// Absent from JSON written before this existed; decodes as `false` there.
    @DecodesAsFalseWhenAbsent public var viaDirect: Bool
    /// True when this reading came from the **degraded tier**: a lockdown
    /// `GetValue` on domain `com.apple.mobile.battery`, which answers while
    /// `diagnostics_relay` is refusing (NOTES.md §13).
    ///
    /// A partial reading carries only `percent`, `isCharging`,
    /// `externalConnected` and `fullyCharged`. Every other numeric field is
    /// `0` and every optional is `nil` — they are *unknown*, not zero. Never
    /// render mAh/watts/temperature/ETA from a partial reading, and never feed
    /// one to `ChargeEstimator` (it refuses them anyway).
    ///
    /// Absent from JSON written before this existed; decodes as `false` there.
    @DecodesAsFalseWhenAbsent public var isPartial: Bool

    public init(
        deviceID: String,
        kind: DeviceKind,
        name: String,
        percent: Int,
        isCharging: Bool,
        externalConnected: Bool,
        fullyCharged: Bool,
        rawCurrentMAh: Int,
        rawMaxMAh: Int,
        designMAh: Int,
        voltageMV: Int,
        instantAmperageMA: Int,
        batteryPowerW: Double,
        systemPowerInW: Double? = nil,
        systemLoadW: Double? = nil,
        adapterWatts: Int? = nil,
        adapterDescription: String? = nil,
        temperatureC: Double,
        cycleCount: Int,
        reportedTimeRemainingMinutes: Int? = nil,
        avgTimeToEmptyMinutes: Int? = nil,
        timestamp: Date,
        transport: Transport,
        viaDirect: Bool = false,
        isPartial: Bool = false
    ) {
        self.deviceID = deviceID
        self.kind = kind
        self.name = name
        self.percent = percent
        self.isCharging = isCharging
        self.externalConnected = externalConnected
        self.fullyCharged = fullyCharged
        self.rawCurrentMAh = rawCurrentMAh
        self.rawMaxMAh = rawMaxMAh
        self.designMAh = designMAh
        self.voltageMV = voltageMV
        self.instantAmperageMA = instantAmperageMA
        self.batteryPowerW = batteryPowerW
        self.systemPowerInW = systemPowerInW
        self.systemLoadW = systemLoadW
        self.adapterWatts = adapterWatts
        self.adapterDescription = adapterDescription
        self.temperatureC = temperatureC
        self.cycleCount = cycleCount
        self.reportedTimeRemainingMinutes = reportedTimeRemainingMinutes
        self.avgTimeToEmptyMinutes = avgTimeToEmptyMinutes
        self.timestamp = timestamp
        self.transport = transport
        self.viaDirect = viaDirect
        self.isPartial = isPartial
    }

    /// Battery health as a fraction of design capacity (1.0 == new).
    public var healthFraction: Double? {
        guard designMAh > 0 else { return nil }
        return Double(rawMaxMAh) / Double(designMAh)
    }
}

extension BatteryReading {

    /// Build a **partial** reading from the four fields lockdown's
    /// `com.apple.mobile.battery` domain reports.
    ///
    /// Everything the domain does not carry is left at `0`/`nil` and flagged by
    /// `isPartial`. See NOTES.md §13 for the rule callers must follow.
    public static func partial(
        deviceID: String,
        kind: DeviceKind = .iphone,
        name: String,
        percent: Int,
        isCharging: Bool,
        externalConnected: Bool,
        fullyCharged: Bool = false,
        timestamp: Date = Date(),
        transport: Transport = .wifi,
        viaDirect: Bool = false
    ) -> BatteryReading {
        BatteryReading(
            deviceID: deviceID,
            kind: kind,
            name: name,
            percent: percent,
            isCharging: isCharging,
            externalConnected: externalConnected,
            fullyCharged: fullyCharged,
            rawCurrentMAh: 0,
            rawMaxMAh: 0,
            designMAh: 0,
            voltageMV: 0,
            instantAmperageMA: 0,
            batteryPowerW: 0,
            systemPowerInW: nil,
            systemLoadW: nil,
            adapterWatts: nil,
            adapterDescription: nil,
            temperatureC: 0,
            cycleCount: 0,
            reportedTimeRemainingMinutes: nil,
            avgTimeToEmptyMinutes: nil,
            timestamp: timestamp,
            transport: transport,
            viaDirect: viaDirect,
            isPartial: true
        )
    }

    /// Fold a fresh partial reading into this (full) one.
    ///
    /// Keeps every detail field of the last full read — mAh, amperage, watts,
    /// adapter, temperature, the gas-gauge minutes — and takes only what the
    /// battery domain actually knows: percent, charging, external, fully
    /// charged, and the timestamp. The result is still flagged `isPartial`, so
    /// the UI can dim the columns whose basis is now older than `timestamp`.
    public func updated(withPartial partial: BatteryReading) -> BatteryReading {
        var merged = self
        merged.percent = partial.percent
        merged.isCharging = partial.isCharging
        merged.externalConnected = partial.externalConnected
        merged.fullyCharged = partial.fullyCharged
        merged.timestamp = partial.timestamp
        merged.transport = partial.transport
        merged.viaDirect = partial.viaDirect
        merged.name = partial.name.isEmpty ? merged.name : partial.name
        merged.isPartial = true
        return merged
    }
}
