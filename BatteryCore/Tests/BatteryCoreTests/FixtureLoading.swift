import Foundation
import Testing
@testable import BatteryCore

enum Fixture: String, CaseIterable {
    case iphoneChargingUSB = "iphone-charging-usb"
    case iphoneChargingWiFi = "iphone-charging-wifi"
    case iphoneDischargingWiFi = "iphone-discharging-wifi"
    case macDischarging = "mac-discharging"
    /// A Mac sitting on a 140 W brick with `Amperage == 0`: the reading where
    /// battery current says nothing and only `PowerTelemetryData` does.
    case macPluggedNotCharging = "mac-plugged-not-charging"

    var data: Data {
        get throws {
            guard let url = Bundle.module.url(
                forResource: rawValue,
                withExtension: "plist",
                subdirectory: "Fixtures"
            ) else {
                Issue.record("fixture \(rawValue).plist is missing from the test bundle")
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
    }
}

/// A fixed instant so nothing in the tests depends on the wall clock.
let referenceDate = Date(timeIntervalSince1970: 1_788_771_435)
