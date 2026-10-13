import Foundation
import Testing
@testable import BatteryCore

@Suite("ChargeEstimator")
struct ChargeEstimatorTests {

    private func iPhoneCharging() throws -> BatteryReading {
        try BatteryPlistParser.parseIPhone(
            Fixture.iphoneChargingUSB.data,
            deviceID: "phone", name: "iPhone", transport: .usb, timestamp: referenceDate
        )
    }

    @Test("1370/4966 mAh at 2954 mA reaches 80 % in about 53 minutes")
    func etaTo80() throws {
        var estimator = ChargeEstimator()
        let estimate = estimator.ingest(try iPhoneCharging())
        let eta = try #require(estimate.etaTo80)
        // (0.8 * 4966 - 1370) / 2954 h == 0.8811 h == 52.9 min
        #expect(abs(eta / 60 - 52.87) < 0.05)
        #expect(StatusFormatter.shortDuration(eta, units: .english) == "53 min")
        #expect(estimate.timeToEmpty == nil)
    }

    @Test("The first sample seeds the EMA, later ones blend at alpha")
    func emaBlending() throws {
        var estimator = ChargeEstimator(alpha: 0.3)
        var reading = try iPhoneCharging()

        #expect(estimator.ingest(reading).smoothedCurrentMA == 2954)
        reading.instantAmperageMA = 1000
        // 0.3 * 1000 + 0.7 * 2954 = 2367.8
        #expect(abs(estimator.ingest(reading).smoothedCurrentMA - 2367.8) < 0.001)
        reading.instantAmperageMA = 1000
        // 0.3 * 1000 + 0.7 * 2367.8 = 1957.46
        #expect(abs(estimator.ingest(reading).smoothedCurrentMA - 1957.46) < 0.001)

        // A different device gets its own history.
        var other = reading
        other.deviceID = "other"
        other.instantAmperageMA = 500
        #expect(estimator.ingest(other).smoothedCurrentMA == 500)
        #expect(estimator.smoothedCurrentMA.count == 2)

        estimator.forget("other")
        #expect(estimator.smoothedCurrentMA.count == 1)
        estimator.reset()
        #expect(estimator.smoothedCurrentMA.isEmpty)
    }

    @Test("Past 80 % the ETA counts to 100 %, and stops there")
    func etaTo100PastEighty() throws {
        var reading = try iPhoneCharging()
        reading.percent = 80
        reading.rawCurrentMAh = 3980
        // (4966 - 3980) mAh / 2954 mA ≈ 20 min.
        let eta = try #require(ChargeEstimator.estimate(for: reading, smoothedCurrentMA: 2954).etaTo80)
        #expect(abs(eta - 1202) < 2)
        #expect(ChargeEstimator.targetPercent(for: 79) == 80)
        #expect(ChargeEstimator.targetPercent(for: 80) == 100)

        reading.percent = 100
        reading.rawCurrentMAh = 4966
        #expect(ChargeEstimator.estimate(for: reading, smoothedCurrentMA: 2954).etaTo80 == nil)
    }

    @Test("No ETA below the 50 mA trickle floor")
    func noEtaOnTrickle() throws {
        let reading = try iPhoneCharging()
        #expect(ChargeEstimator.estimate(for: reading, smoothedCurrentMA: 49).etaTo80 == nil)
        #expect(ChargeEstimator.estimate(for: reading, smoothedCurrentMA: 50).etaTo80 != nil)
    }

    @Test("Charging watts prefer wall power, and vanish when not charging")
    func chargingWatts() throws {
        let charging = try iPhoneCharging()
        #expect(ChargeEstimator.chargingWatts(for: charging) == 13.049)

        // Without telemetry, fall back to the power entering the cell.
        var noTelemetry = charging
        noTelemetry.systemPowerInW = nil
        #expect(ChargeEstimator.chargingWatts(for: noTelemetry) == 11.149)

        var discharging = charging
        discharging.isCharging = false
        #expect(ChargeEstimator.chargingWatts(for: discharging) == nil)
    }

    @Test("Discharging iPhone uses AvgTimeToEmpty, not TimeRemaining")
    func iPhoneTimeToEmpty() throws {
        let reading = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneDischargingWiFi.data,
            deviceID: "phone", name: "iPhone", transport: .wifi, timestamp: referenceDate
        )
        var estimator = ChargeEstimator()
        let estimate = estimator.ingest(reading)
        #expect(estimate.etaTo80 == nil)
        #expect(estimate.chargingWatts == nil)
        #expect(estimate.timeToEmpty == Double(696 * 60))
    }

    @Test("Discharging Mac uses its own TimeRemaining")
    func macTimeToEmpty() throws {
        let reading = try BatteryPlistParser.parseMac(
            Fixture.macDischarging.data, deviceID: "mac", name: "MacBook Pro", timestamp: referenceDate
        )
        var estimator = ChargeEstimator()
        let estimate = estimator.ingest(reading)
        #expect(estimate.timeToEmpty == Double(166 * 60))
        #expect(StatusFormatter.clockDuration(try #require(estimate.timeToEmpty)) == "2:46")
    }

    @Test("Without a device estimate, time-to-empty falls back to mAh over current")
    func computedTimeToEmpty() throws {
        var reading = try BatteryPlistParser.parseMac(
            Fixture.macDischarging.data, deviceID: "mac", name: "MacBook Pro", timestamp: referenceDate
        )
        reading.reportedTimeRemainingMinutes = nil
        reading.avgTimeToEmptyMinutes = nil
        let estimate = ChargeEstimator.estimate(for: reading, smoothedCurrentMA: -2724)
        // 6404 mAh / 2724 mA = 2.3510 h = 141.06 min
        #expect(abs(try #require(estimate.timeToEmpty) / 60 - 141.06) < 0.05)

        // Below the floor there is nothing trustworthy to say.
        #expect(ChargeEstimator.estimate(for: reading, smoothedCurrentMA: -49).timeToEmpty == nil)
    }
}
