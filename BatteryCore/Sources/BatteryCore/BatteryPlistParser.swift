import Foundation

/// Errors raised while decoding an `AppleSmartBattery` property dump.
public enum BatteryParseError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The top-level container was neither a dict nor a one-element array of dicts.
    case notADictionary
    /// The property list itself could not be decoded.
    case malformedPlist(String)
    /// A key we require was absent (or not an integer/bool where one was needed).
    case missingKey(String)

    public var description: String {
        switch self {
        case .notADictionary:
            return "AppleSmartBattery dump did not contain a dictionary at the top level"
        case .malformedPlist(let detail):
            return "Malformed property list: \(detail)"
        case .missingKey(let key):
            return "Missing required AppleSmartBattery key: \(key)"
        }
    }
}

/// Decodes `AppleSmartBattery` IORegistry dumps from both platforms into a
/// `BatteryReading`.
///
/// The two dumps differ only in packaging:
/// * iPhone (`idevicediagnostics ioregentry AppleSmartBattery`) nests everything
///   under a top-level `IORegistry` key.
/// * Mac (`ioreg -a -rc AppleSmartBattery`, and IOKit directly) hands back a
///   one-element array of dictionaries, or the dictionary itself.
public enum BatteryPlistParser {

    // MARK: - Number normalisation

    /// IORegistry integers are frequently stored unsigned, so a negative current
    /// arrives as its 64-bit two's-complement bit pattern (e.g. `-1001` shows up
    /// as `18446744073709550615`). Reinterpret anything in the top half of the
    /// unsigned range as the signed value it really is.
    public static func normalizedInt(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? 1 : 0
            }
            let unsigned = number.uint64Value
            if unsigned > UInt64(Int64.max) / 2 {
                return Int(Int64(bitPattern: unsigned))
            }
            return Int(number.int64Value)
        case let unsigned as UInt64:
            if unsigned > UInt64(Int64.max) / 2 {
                return Int(Int64(bitPattern: unsigned))
            }
            return Int(unsigned)
        case let signed as Int:
            return signed
        case let signed as Int64:
            return Int(signed)
        case let text as String:
            return Int(text)
        default:
            return nil
        }
    }

    static func normalizedBool(_ value: Any?) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let flag = value as? Bool { return flag }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        }
        return nil
    }

    // MARK: - Container unwrapping

    /// Pull the `AppleSmartBattery` property dictionary out of raw plist bytes,
    /// tolerating either platform's packaging.
    public static func rootDictionary(from data: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw BatteryParseError.malformedPlist(error.localizedDescription)
        }
        return try rootDictionary(from: object)
    }

    /// Same as above but starting from an already-deserialised plist object.
    public static func rootDictionary(from object: Any) throws -> [String: Any] {
        if let array = object as? [Any] {
            guard let first = array.first else { throw BatteryParseError.notADictionary }
            return try rootDictionary(from: first)
        }
        guard var dict = object as? [String: Any] else { throw BatteryParseError.notADictionary }
        // iOS wraps the whole entry in an "IORegistry" dictionary.
        if dict["CurrentCapacity"] == nil, let nested = dict["IORegistry"] as? [String: Any] {
            dict = nested
        }
        return dict
    }

    // MARK: - Entry points

    /// Decode an iPhone `ioregentry AppleSmartBattery` dump.
    public static func parseIPhone(
        _ data: Data,
        deviceID: String? = nil,
        name: String = "iPhone",
        transport: Transport = .usb,
        timestamp: Date = Date()
    ) throws -> BatteryReading {
        try parse(
            dictionary: try rootDictionary(from: data),
            kind: .iphone,
            deviceID: deviceID,
            name: name,
            transport: transport,
            timestamp: timestamp
        )
    }

    /// Decode a Mac `ioreg -a -rc AppleSmartBattery` dump (or IOKit properties).
    public static func parseMac(
        _ data: Data,
        deviceID: String? = nil,
        name: String = "Mac",
        transport: Transport = .local,
        timestamp: Date = Date()
    ) throws -> BatteryReading {
        try parse(
            dictionary: try rootDictionary(from: data),
            kind: .mac,
            deviceID: deviceID,
            name: name,
            transport: transport,
            timestamp: timestamp
        )
    }

    /// The lockdown domain that answers while `diagnostics_relay` will not.
    public static let batteryDomain = "com.apple.mobile.battery"

    /// Decode a lockdown `GetValue` reply for domain `com.apple.mobile.battery`
    /// into a **partial** reading.
    ///
    /// The domain carries exactly four keys — `BatteryCurrentCapacity`,
    /// `BatteryIsCharging`, `ExternalConnected`, `FullyCharged` — so everything
    /// else in the returned `BatteryReading` is `0`/`nil` and `isPartial` is
    /// `true`. See NOTES.md §13.
    public static func parseBatteryDomain(
        _ data: Data,
        deviceID: String,
        name: String = "iPhone",
        transport: Transport = .wifi,
        viaDirect: Bool = false,
        timestamp: Date = Date()
    ) throws -> BatteryReading {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw BatteryParseError.malformedPlist(error.localizedDescription)
        }
        guard let dictionary = object as? [String: Any] else {
            throw BatteryParseError.notADictionary
        }
        return try parseBatteryDomain(
            dictionary: dictionary,
            deviceID: deviceID,
            name: name,
            transport: transport,
            viaDirect: viaDirect,
            timestamp: timestamp
        )
    }

    public static func parseBatteryDomain(
        dictionary: [String: Any],
        deviceID: String,
        name: String = "iPhone",
        transport: Transport = .wifi,
        viaDirect: Bool = false,
        timestamp: Date = Date()
    ) throws -> BatteryReading {
        guard let percent = normalizedInt(dictionary["BatteryCurrentCapacity"]) else {
            throw BatteryParseError.missingKey("BatteryCurrentCapacity")
        }
        guard let isCharging = normalizedBool(dictionary["BatteryIsCharging"]) else {
            throw BatteryParseError.missingKey("BatteryIsCharging")
        }
        return BatteryReading.partial(
            deviceID: deviceID,
            kind: .iphone,
            name: name,
            percent: percent,
            isCharging: isCharging,
            externalConnected: normalizedBool(dictionary["ExternalConnected"]) ?? isCharging,
            fullyCharged: normalizedBool(dictionary["FullyCharged"]) ?? false,
            timestamp: timestamp,
            transport: transport,
            viaDirect: viaDirect
        )
    }

    // MARK: - Shared decoder

    /// The one decoder both platforms go through.
    public static func parse(
        dictionary: [String: Any],
        kind: DeviceKind,
        deviceID: String? = nil,
        name: String,
        transport: Transport,
        timestamp: Date = Date()
    ) throws -> BatteryReading {

        func requiredInt(_ key: String) throws -> Int {
            guard let value = normalizedInt(dictionary[key]) else {
                throw BatteryParseError.missingKey(key)
            }
            return value
        }
        func requiredBool(_ key: String) throws -> Bool {
            guard let value = normalizedBool(dictionary[key]) else {
                throw BatteryParseError.missingKey(key)
            }
            return value
        }
        func optionalInt(_ key: String) -> Int? { normalizedInt(dictionary[key]) }

        let currentCapacity = try requiredInt("CurrentCapacity")
        let maxCapacity = try requiredInt("MaxCapacity")
        // iOS 27 dropped the AppleRaw* mAh keys; BatteryData still carries them.
        let batteryData = dictionary["BatteryData"] as? [String: Any]
        func batteryDataInt(_ key: String) -> Int? { normalizedInt(batteryData?[key]) }
        guard let rawCurrent = optionalInt("AppleRawCurrentCapacity")
            ?? batteryDataInt("TrueRemainingCapacity") ?? batteryDataInt("RemainingCapacity") else {
            throw BatteryParseError.missingKey("AppleRawCurrentCapacity")
        }
        guard let rawMax = optionalInt("AppleRawMaxCapacity")
            ?? batteryDataInt("FullChargeCapacity") ?? batteryDataInt("NominalChargeCapacity") else {
            throw BatteryParseError.missingKey("AppleRawMaxCapacity")
        }
        let voltageMV = try requiredInt("Voltage")

        // Apple Silicon and iOS report CurrentCapacity as a percentage against
        // MaxCapacity == 100. Intel Macs report mAh; scale in that case.
        let percent: Int
        if maxCapacity == 100 {
            percent = currentCapacity
        } else if maxCapacity > 0 {
            percent = Int((Double(currentCapacity) / Double(maxCapacity) * 100).rounded())
        } else {
            percent = currentCapacity
        }

        // InstantAmperage is the fresher of the two; fall back to Amperage.
        guard let instantAmperage = optionalInt("InstantAmperage") ?? optionalInt("Amperage") else {
            throw BatteryParseError.missingKey("InstantAmperage")
        }

        let isCharging = try requiredBool("IsCharging")
        let externalConnected = try requiredBool("ExternalConnected")
        let fullyCharged = normalizedBool(dictionary["FullyCharged"]) ?? false

        let designMAh = optionalInt("DesignCapacity") ?? optionalInt("NominalChargeCapacity")
            ?? batteryDataInt("DesignCapacity") ?? rawMax

        let telemetry = dictionary["PowerTelemetryData"] as? [String: Any]

        // `BatteryPower` (mW) is signed on iPhone but not on Mac -- the Mac dump
        // reports a positive value while discharging -- so take the magnitude
        // from telemetry and the sign from the current, which is always signed.
        let computedMagnitudeW = abs(Double(voltageMV) * Double(instantAmperage) / 1_000_000.0)
        let telemetryMagnitudeW = normalizedInt(telemetry?["BatteryPower"]).map { abs(Double($0)) / 1000.0 }
        let magnitudeW = telemetryMagnitudeW ?? computedMagnitudeW
        let flowingIn = instantAmperage != 0 ? instantAmperage > 0 : isCharging
        let batteryPowerW = flowingIn ? magnitudeW : -magnitudeW

        // SystemPowerIn is 0 (not absent) when running on battery. Both
        // platforms report it, and so does the Mac while it is plugged in and
        // *not* charging — which is the only number that answers "what is
        // coming out of the wall" there, since Amperage is then 0.
        let systemPowerInW = normalizedInt(telemetry?["SystemPowerIn"])
            .flatMap { $0 > 0 ? Double($0) / 1000.0 : nil }

        // Raw PowerTelemetryData.SystemLoad, kept for diagnostics. Its sign is
        // not portable -- the Mac reports -32554 mW on battery and +13307 mW
        // on the adapter, the iPhone reports +440 mW on battery -- so keep the
        // magnitude. 0 means "not reported".
        let telemetrySystemLoadW = normalizedInt(telemetry?["SystemLoad"])
            .flatMap { $0 != 0 ? abs(Double($0)) / 1000.0 : nil }

        // What the machine itself is drawing. On the iPhone, telemetry's
        // SystemLoad already answers this. On the Mac it does not -- it is an
        // aggregate equal to SystemPowerIn - BatteryPower, not the machine's
        // own consumption (measured live: SystemLoad 87692 mW while the
        // reference tool showed the system at 23 W). The honest figure there
        // is SystemPowerIn minus what is moving into/out of the pack -- signed
        // battery charge power, positive while charging -- falling back to
        // that quantity's magnitude when SystemPowerIn is unknown (on
        // battery). See NOTES.md §6.
        let systemLoadW: Double?
        if kind == .mac {
            let batteryChargeW = Double(voltageMV) * Double(instantAmperage) / 1_000_000.0
            if let systemPowerInW {
                systemLoadW = max(0, systemPowerInW - batteryChargeW)
            } else {
                systemLoadW = abs(batteryChargeW) > 0 ? abs(batteryChargeW) : nil
            }
        } else {
            systemLoadW = telemetrySystemLoadW
        }

        let adapter = dictionary["AdapterDetails"] as? [String: Any]
        let adapterWatts = normalizedInt(adapter?["Watts"]).flatMap { $0 > 0 ? $0 : nil }
        let adapterDescription = (adapter?["Description"] as? String)
            ?? (adapter?["Name"] as? String)

        let temperatureC = Double(optionalInt("Temperature") ?? 0) / 100.0
        let cycleCount = optionalInt("CycleCount")
            ?? batteryDataInt("CycleCount")
            ?? 0

        // 65535 is the "unknown" sentinel. TimeRemaining is unreliable while an
        // iPhone charges, so callers only use it for the Mac; AvgTimeToEmpty is
        // usable on both while discharging.
        func sanitizedMinutes(_ key: String) -> Int? {
            optionalInt(key).flatMap { $0 > 0 && $0 < 6000 ? $0 : nil }
        }
        let reportedTimeRemaining = sanitizedMinutes("TimeRemaining")
        let avgTimeToEmpty = sanitizedMinutes("AvgTimeToEmpty")

        let serial = dictionary["Serial"] as? String
        let resolvedID = deviceID ?? serial ?? kind.rawValue

        return BatteryReading(
            deviceID: resolvedID,
            kind: kind,
            name: name,
            percent: percent,
            isCharging: isCharging,
            externalConnected: externalConnected,
            fullyCharged: fullyCharged,
            rawCurrentMAh: rawCurrent,
            rawMaxMAh: rawMax,
            designMAh: designMAh,
            voltageMV: voltageMV,
            instantAmperageMA: instantAmperage,
            batteryPowerW: batteryPowerW,
            systemPowerInW: systemPowerInW,
            systemLoadW: systemLoadW,
            telemetrySystemLoadW: telemetrySystemLoadW,
            adapterWatts: adapterWatts,
            adapterDescription: adapterDescription,
            temperatureC: temperatureC,
            cycleCount: cycleCount,
            reportedTimeRemainingMinutes: reportedTimeRemaining,
            avgTimeToEmptyMinutes: avgTimeToEmpty,
            timestamp: timestamp,
            transport: transport
        )
    }
}
