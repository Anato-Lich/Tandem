import Foundation
import Testing
@testable import BatteryCore

@Suite("BatteryPlistParser")
struct ParserTests {

    // MARK: - iPhone, charging

    @Test("iPhone charging fixture decodes to the documented values", arguments: [
        Fixture.iphoneChargingUSB, Fixture.iphoneChargingWiFi,
    ])
    func iPhoneCharging(fixture: Fixture) throws {
        let reading = try BatteryPlistParser.parseIPhone(
            fixture.data,
            deviceID: "00001111-000A1B2C3D4E5F60",
            name: "iPhone",
            transport: fixture == .iphoneChargingUSB ? .usb : .wifi,
            timestamp: referenceDate
        )

        #expect(reading.kind == .iphone)
        #expect(reading.percent == 28)
        #expect(reading.isCharging)
        #expect(reading.externalConnected)
        #expect(reading.fullyCharged == false)
        #expect(reading.rawCurrentMAh == 1370)
        #expect(reading.rawMaxMAh == 4966)
        #expect(reading.designMAh == 4768)
        #expect(reading.voltageMV == 3875)
        #expect(reading.instantAmperageMA == 2954)
        #expect(reading.cycleCount == 14)
        #expect(reading.temperatureC == 28.89)
        #expect(reading.adapterWatts == 15)
        #expect(reading.adapterDescription == "pd charger")
        // PowerTelemetryData: SystemPowerIn 13049 mW, BatteryPower 11149 mW.
        #expect(reading.systemPowerInW == 13.049)
        #expect(reading.batteryPowerW == 11.149)
        #expect(reading.transport == (fixture == .iphoneChargingUSB ? .usb : .wifi))
        #expect(reading.timestamp == referenceDate)
    }

    @Test("USB and Wi-Fi dumps of the same moment parse identically")
    func transportsAgree() throws {
        let usb = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingUSB.data, timestamp: referenceDate)
        let wifi = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingWiFi.data, timestamp: referenceDate)
        #expect(usb == wifi)
    }

    // MARK: - iPhone, discharging

    @Test("iPhone discharging fixture decodes, including the negative current")
    func iPhoneDischarging() throws {
        let reading = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneDischargingWiFi.data,
            deviceID: "00001111-000A1B2C3D4E5F60",
            name: "iPhone",
            transport: .wifi,
            timestamp: referenceDate
        )

        #expect(reading.percent == 35)
        #expect(reading.isCharging == false)
        #expect(reading.externalConnected == false)
        #expect(reading.rawCurrentMAh == 1725)
        #expect(reading.rawMaxMAh == 4974)
        #expect(reading.voltageMV == 3832)
        #expect(reading.instantAmperageMA == -113)
        #expect(reading.avgTimeToEmptyMinutes == 696)
        // SystemPowerIn is 0 while on battery, which must read as "unknown".
        #expect(reading.systemPowerInW == nil)
        // BatteryPower -440 mW, negative because it is leaving the cell.
        #expect(reading.batteryPowerW == -0.44)
        // Watts == 0 while unplugged is not an adapter.
        #expect(reading.adapterWatts == nil)
        #expect(reading.adapterDescription == "batt")
    }

    // MARK: - Mac

    @Test("Mac fixture decodes, with the discharge sign applied")
    func macDischarging() throws {
        let reading = try BatteryPlistParser.parseMac(
            Fixture.macDischarging.data,
            deviceID: "mac",
            name: "MacBook Pro",
            timestamp: referenceDate
        )

        #expect(reading.kind == .mac)
        #expect(reading.transport == .local)
        #expect(reading.percent == 81)
        #expect(reading.isCharging == false)
        #expect(reading.externalConnected == false)
        #expect(reading.rawCurrentMAh == 6404)
        #expect(reading.rawMaxMAh == 8355)
        #expect(reading.designMAh == 8579)
        #expect(reading.voltageMV == 12108)
        #expect(reading.instantAmperageMA == -2724)
        #expect(reading.cycleCount == 33)
        #expect(reading.temperatureC == 30.29)
        #expect(reading.reportedTimeRemainingMinutes == 166)
        // AdapterDetails carries only FamilyCode while unplugged.
        #expect(reading.adapterWatts == nil)
        #expect(reading.adapterDescription == nil)
        // The Mac reports BatteryPower as an unsigned 32554 mW while
        // discharging; the sign has to come from the current.
        #expect(reading.batteryPowerW == -32.554)
        #expect(reading.systemPowerInW == nil)
    }

    @Test("Plugged and not charging: the watts come from PowerTelemetryData")
    func macPluggedNotCharging() throws {
        let reading = try BatteryPlistParser.parseMac(
            Fixture.macPluggedNotCharging.data,
            deviceID: "mac",
            name: "MacBook Pro",
            timestamp: referenceDate
        )

        #expect(reading.percent == 90)
        #expect(reading.isCharging == false)
        #expect(reading.externalConnected == true)
        // The whole point of the fixture: no current is flowing into or out of
        // the pack, so Amperage x Voltage is 0 W and would be reported as
        // "draw 0 W" if it were the only source.
        #expect(reading.instantAmperageMA == 0)
        #expect(reading.batteryPowerW == 0)
        // SystemLoad 13307 mW -- what the Mac is actually consuming.
        #expect(reading.systemLoadW == 13.307)
        // SystemPowerIn 13307 mW -- what the adapter is actually supplying.
        #expect(reading.systemPowerInW == 13.307)
        // AdapterDetails.Watts -- what it *could* supply.
        #expect(reading.adapterWatts == 140)
        #expect(reading.adapterDescription == "pd charger")
        // Nothing is charging, so no charge watts and no ETA.
        #expect(ChargeEstimator.chargingWatts(for: reading) == nil)
    }

    @Test("SystemLoad's sign is not portable, so the magnitude is kept")
    func systemLoadMagnitude() throws {
        // Mac on battery: SystemLoad -32554 mW, BatteryPower +32554 mW.
        let mac = try BatteryPlistParser.parseMac(Fixture.macDischarging.data, timestamp: referenceDate)
        #expect(mac.systemLoadW == 32.554)
        // iPhone on battery: SystemLoad +440 mW, BatteryPower -440 mW.
        let phone = try BatteryPlistParser.parseIPhone(Fixture.iphoneDischargingWiFi.data, timestamp: referenceDate)
        #expect(phone.systemLoadW == 0.44)
        // iPhone charging: the phone's own consumption, not the wall power.
        let charging = try BatteryPlistParser.parseIPhone(Fixture.iphoneChargingUSB.data, timestamp: referenceDate)
        #expect(charging.systemLoadW == 1.9)
        #expect(charging.systemPowerInW == 13.049)
    }

    @Test("A SystemLoad stored as an unsigned two's complement still decodes")
    func systemLoadUnsigned() throws {
        var dictionary = try BatteryPlistParser.rootDictionary(from: Fixture.macDischarging.data)
        var telemetry = dictionary["PowerTelemetryData"] as! [String: Any]
        // What IOKit hands back for -32554 when the key is stored unsigned.
        telemetry["SystemLoad"] = UInt64(bitPattern: Int64(-32554))
        dictionary["PowerTelemetryData"] = telemetry
        let reading = try BatteryPlistParser.parse(
            dictionary: dictionary, kind: .mac, name: "MacBook Pro", transport: .local
        )
        #expect(reading.systemLoadW == 32.554)
    }

    @Test("Mac dumps come wrapped in a one-element array")
    func macArrayWrapper() throws {
        let root = try BatteryPlistParser.rootDictionary(from: Fixture.macDischarging.data)
        #expect(root["CurrentCapacity"] != nil)
    }

    @Test("iPhone dumps come wrapped in an IORegistry dictionary")
    func iPhoneWrapper() throws {
        let object = try PropertyListSerialization.propertyList(
            from: Fixture.iphoneChargingUSB.data, options: [], format: nil
        )
        #expect((object as? [String: Any])?["IORegistry"] != nil)
        let root = try BatteryPlistParser.rootDictionary(from: object)
        #expect(BatteryPlistParser.normalizedInt(root["CurrentCapacity"]) == 28)
    }

    // MARK: - Integer normalisation

    @Test("UInt64 two's-complement integers decode as negative")
    func unsignedNegatives() {
        // What macOS ioreg prints for -1001.
        #expect(BatteryPlistParser.normalizedInt(NSNumber(value: UInt64(18_446_744_073_709_550_615))) == -1001)
        #expect(BatteryPlistParser.normalizedInt(UInt64(bitPattern: Int64(-2724))) == -2724)
        #expect(BatteryPlistParser.normalizedInt(NSNumber(value: UInt64(bitPattern: Int64(-113)))) == -113)
        // Positives are untouched.
        #expect(BatteryPlistParser.normalizedInt(NSNumber(value: 2954)) == 2954)
        #expect(BatteryPlistParser.normalizedInt(NSNumber(value: Int64(-2724))) == -2724)
        #expect(BatteryPlistParser.normalizedInt(0) == 0)
        #expect(BatteryPlistParser.normalizedInt("4966") == 4966)
        #expect(BatteryPlistParser.normalizedInt(nil) == nil)
        #expect(BatteryPlistParser.normalizedInt(["nope"]) == nil)
    }

    @Test("A whole dictionary of unsigned values parses with the right signs")
    func unsignedDictionary() throws {
        let dictionary: [String: Any] = [
            "CurrentCapacity": 84,
            "MaxCapacity": 100,
            "AppleRawCurrentCapacity": 6691,
            "AppleRawMaxCapacity": 8395,
            "DesignCapacity": 8579,
            "Voltage": 12305,
            "InstantAmperage": NSNumber(value: UInt64(18_446_744_073_709_550_615)), // -1001
            "Amperage": NSNumber(value: UInt64(18_446_744_073_709_550_615)),
            "IsCharging": false,
            "ExternalConnected": false,
            "FullyCharged": false,
            "Temperature": 3016,
            "CycleCount": 33,
            "TimeRemaining": 65535, // the "unknown" sentinel
        ]
        let reading = try BatteryPlistParser.parse(
            dictionary: dictionary, kind: .mac, name: "MacBook Pro",
            transport: .local, timestamp: referenceDate
        )
        #expect(reading.instantAmperageMA == -1001)
        #expect(reading.percent == 84)
        #expect(reading.reportedTimeRemainingMinutes == nil)
        // 12305 mV * -1001 mA = -12.317 W
        #expect(abs(reading.batteryPowerW - -12.317305) < 0.000_001)
    }

    @Test("Intel-style mAh capacities are converted to a percentage")
    func intelStylePercent() throws {
        let dictionary: [String: Any] = [
            "CurrentCapacity": 3000,
            "MaxCapacity": 4000,
            "AppleRawCurrentCapacity": 3000,
            "AppleRawMaxCapacity": 4000,
            "Voltage": 12000,
            "InstantAmperage": -500,
            "IsCharging": false,
            "ExternalConnected": false,
        ]
        let reading = try BatteryPlistParser.parse(
            dictionary: dictionary, kind: .mac, name: "MacBook", transport: .local
        )
        #expect(reading.percent == 75)
    }

    // MARK: - Errors

    @Test("A missing key is reported by name")
    func missingKey() throws {
        var dictionary = try BatteryPlistParser.rootDictionary(from: Fixture.macDischarging.data)
        dictionary.removeValue(forKey: "Voltage")
        #expect(throws: BatteryParseError.missingKey("Voltage")) {
            _ = try BatteryPlistParser.parse(
                dictionary: dictionary, kind: .mac, name: "MacBook Pro", transport: .local
            )
        }
    }

    @Test("Both currents missing is reported against InstantAmperage")
    func missingCurrent() throws {
        var dictionary = try BatteryPlistParser.rootDictionary(from: Fixture.macDischarging.data)
        dictionary.removeValue(forKey: "InstantAmperage")
        dictionary.removeValue(forKey: "Amperage")
        #expect(throws: BatteryParseError.missingKey("InstantAmperage")) {
            _ = try BatteryPlistParser.parse(
                dictionary: dictionary, kind: .mac, name: "MacBook Pro", transport: .local
            )
        }
    }

    @Test("Amperage is used when InstantAmperage is absent")
    func amperageFallback() throws {
        var dictionary = try BatteryPlistParser.rootDictionary(from: Fixture.iphoneDischargingWiFi.data)
        dictionary.removeValue(forKey: "InstantAmperage")
        let reading = try BatteryPlistParser.parse(
            dictionary: dictionary, kind: .iphone, name: "iPhone", transport: .wifi
        )
        #expect(reading.instantAmperageMA == -115)
    }

    @Test("Garbage input throws rather than crashing")
    func garbage() {
        #expect(throws: BatteryParseError.self) {
            _ = try BatteryPlistParser.parseMac(Data("not a plist".utf8))
        }
        #expect(throws: BatteryParseError.notADictionary) {
            _ = try BatteryPlistParser.rootDictionary(from: [Any]())
        }
    }
}
