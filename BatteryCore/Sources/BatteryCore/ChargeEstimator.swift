import Foundation

/// Derived numbers for one device at one instant.
public struct ChargeEstimate: Sendable, Codable, Equatable {
    /// Seconds until the pack reaches 80 %, or nil when not meaningfully charging.
    public var etaTo80: TimeInterval?
    /// Seconds until empty, or nil when charging / current too small to trust.
    public var timeToEmpty: TimeInterval?
    /// Watts being pulled while charging (wall power if known, else battery power).
    public var chargingWatts: Double?
    /// The exponentially smoothed current (mA, signed) used for the maths above.
    public var smoothedCurrentMA: Double

    public init(
        etaTo80: TimeInterval? = nil,
        timeToEmpty: TimeInterval? = nil,
        chargingWatts: Double? = nil,
        smoothedCurrentMA: Double = 0
    ) {
        self.etaTo80 = etaTo80
        self.timeToEmpty = timeToEmpty
        self.chargingWatts = chargingWatts
        self.smoothedCurrentMA = smoothedCurrentMA
    }
}

/// Pure, value-semantic charge maths.
///
/// Instantaneous current is noisy (a phone's `InstantAmperage` swings by
/// hundreds of mA between samples), so every estimate runs off an exponential
/// moving average kept per device id.
public struct ChargeEstimator: Sendable, Equatable {

    /// Smallest |current| we will divide by, in mA.
    public static let minimumUsableCurrentMA: Double = 50

    public let alpha: Double
    /// EMA of signed current per device id. Exposed so a caller can persist or
    /// seed it.
    public private(set) var smoothedCurrentMA: [String: Double] = [:]

    public init(alpha: Double = 0.3) {
        precondition(alpha > 0 && alpha <= 1, "alpha must be in (0, 1]")
        self.alpha = alpha
    }

    /// Fold a reading into the EMA and return the estimate for it.
    ///
    /// A **partial** reading (NOTES.md §13) is deliberately *not* folded in: its
    /// `instantAmperageMA` is `0` because the battery domain does not report
    /// current, not because no current is flowing, and one such sample would
    /// drag the EMA to a third of its true value. Partial readings return an
    /// estimate carrying only the existing smoothed current, with no ETA at all;
    /// the caller is expected to keep displaying the last full reading's numbers
    /// and to dim them using `DeviceStatus.detailAge`.
    @discardableResult
    public mutating func ingest(_ reading: BatteryReading) -> ChargeEstimate {
        guard !reading.isPartial else {
            return ChargeEstimate(smoothedCurrentMA: smoothedCurrentMA[reading.deviceID] ?? 0)
        }
        let sample = Double(reading.instantAmperageMA)
        let smoothed: Double
        if let previous = smoothedCurrentMA[reading.deviceID] {
            smoothed = alpha * sample + (1 - alpha) * previous
        } else {
            smoothed = sample
        }
        smoothedCurrentMA[reading.deviceID] = smoothed
        return Self.estimate(for: reading, smoothedCurrentMA: smoothed)
    }

    /// Drop a device's history (e.g. after it disappears for a long while).
    public mutating func forget(_ deviceID: String) {
        smoothedCurrentMA.removeValue(forKey: deviceID)
    }

    public mutating func reset() {
        smoothedCurrentMA.removeAll()
    }

    /// Restore an EMA saved earlier (or carried across a configuration change,
    /// so `TandemMonitor.update(configuration:)` can change `alpha` without
    /// throwing away the history).
    public mutating func seed(_ values: [String: Double]) {
        for (deviceID, value) in values { smoothedCurrentMA[deviceID] = value }
    }

    /// The maths, with no state at all: given a reading and a smoothed current,
    /// produce the estimate.
    public static func estimate(for reading: BatteryReading, smoothedCurrentMA smoothed: Double) -> ChargeEstimate {
        // A partial reading knows percent and charging and nothing else; there
        // is no capacity or current to divide, so there is no estimate to make.
        guard !reading.isPartial else { return ChargeEstimate(smoothedCurrentMA: smoothed) }
        var estimate = ChargeEstimate(smoothedCurrentMA: smoothed)
        estimate.chargingWatts = chargingWatts(for: reading)

        if reading.isCharging {
            if smoothed >= minimumUsableCurrentMA,
               reading.percent < 80,
               reading.rawMaxMAh > 0 {
                let targetMAh = 0.8 * Double(reading.rawMaxMAh)
                let deficitMAh = targetMAh - Double(reading.rawCurrentMAh)
                if deficitMAh > 0 {
                    estimate.etaTo80 = deficitMAh / smoothed * 3600.0
                }
            }
        } else {
            // Prefer the device's own gas-gauge estimate when it looks sane:
            // AvgTimeToEmpty on iPhone, TimeRemaining on Mac.
            if let minutes = reportedMinutesToEmpty(for: reading) {
                estimate.timeToEmpty = Double(minutes) * 60.0
            } else if -smoothed >= minimumUsableCurrentMA, reading.rawCurrentMAh > 0 {
                estimate.timeToEmpty = Double(reading.rawCurrentMAh) / -smoothed * 3600.0
            }
        }
        return estimate
    }

    /// The device's own minutes-to-empty, when we trust it.
    ///
    /// iPhone `TimeRemaining` is garbage while charging but `AvgTimeToEmpty` is
    /// sound on discharge; the Mac's `TimeRemaining` is the number the OS itself
    /// shows.
    static func reportedMinutesToEmpty(for reading: BatteryReading) -> Int? {
        switch reading.kind {
        case .mac:
            return reading.reportedTimeRemainingMinutes ?? reading.avgTimeToEmptyMinutes
        case .iphone:
            return reading.avgTimeToEmptyMinutes
        }
    }

    /// Watts flowing in while charging: wall power if the device reports it,
    /// otherwise the power actually entering the cell. Nil when not charging.
    public static func chargingWatts(for reading: BatteryReading) -> Double? {
        guard reading.isCharging else { return nil }
        if let wall = reading.systemPowerInW, wall > 0 { return wall }
        let battery = reading.batteryPowerW
        return battery > 0 ? battery : nil
    }
}
