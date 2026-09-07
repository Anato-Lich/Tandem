import Foundation

/// "This device just went past 80 % on the charger" — once per charging session.
///
/// Pure state machine over the snapshot stream: no notification centre, no
/// clock of its own, no UI. `TandemModel` keeps one per device, feeds it every
/// snapshot and posts a notification for whatever comes back.
///
/// The rule, exactly:
///
/// * fires when the percent crosses **from < 80 to ≥ 80 while `isCharging`**;
/// * fires **once per charging session** — the latch is only released when
///   `externalConnected` turns false, i.e. the cable actually comes out;
/// * never fires on the first sample it ever sees, because "crossing" needs a
///   previous percent. A phone that is already at 90 % when the app launches is
///   not news.
///
/// A missed poll (`nil` status) is not an unplug: the session is left alone.
public struct ChargeMilestone: Sendable, Equatable {

    /// The percent the milestone is about. 80 is the only number this app
    /// counts towards anywhere (NOTES.md §9, and the plan's "no 100 %" rule).
    public static let threshold = 80

    /// Everything a notification needs, and nothing it does not.
    public struct Event: Sendable, Equatable {
        public var kind: DeviceKind
        /// The device's own name, for a log line. The notification title is a
        /// fixed, localised string, not this.
        public var deviceName: String
        public var percent: Int
        /// When the crossing was observed (the reading's own timestamp).
        public var at: Date
        /// How long the charging session had been running. `nil` when this
        /// process never saw the session start and nothing seeded one — omit
        /// the "in 23 min" half of the body rather than invent it.
        public var elapsed: TimeInterval?
        /// Watts going in at the crossing: `systemPowerInW` when the device
        /// reports it, else the estimator's `chargingWatts`. `nil` on a partial
        /// reading, where zero would mean *unknown* rather than zero
        /// (NOTES.md §13.2).
        public var watts: Double?
        /// What the adapter is rated for, when it says.
        public var adapterWatts: Int?

        public init(
            kind: DeviceKind,
            deviceName: String,
            percent: Int,
            at: Date,
            elapsed: TimeInterval? = nil,
            watts: Double? = nil,
            adapterWatts: Int? = nil
        ) {
            self.kind = kind
            self.deviceName = deviceName
            self.percent = percent
            self.at = at
            self.elapsed = elapsed
            self.watts = watts
            self.adapterWatts = adapterWatts
        }
    }

    /// The percent at the previous update; `nil` before the first one.
    public private(set) var lastPercent: Int?
    /// Whether the device was on external power at the previous update.
    public private(set) var externalConnected = false
    /// When the current charging session began, as far as we know.
    public private(set) var sessionStart: Date?
    /// True when we actually watched the cable go in, rather than finding the
    /// device already on the charger at the first sample we ever saw.
    ///
    /// An *assumed* start is the app-launched-into-a-charge case, and it is the
    /// only one `seedSessionStart(_:)` is allowed to correct.
    public private(set) var sessionStartIsObserved = false
    /// True once this session's event has been handed out.
    public private(set) var hasFired = false

    public init() {}

    /// Tell the milestone when the session in progress actually began — from
    /// `HistoryStore.sessions`, say, when the app launched into a charge that
    /// was already running and the first sample we saw was half an hour into it.
    ///
    /// Ignored unless a session is in progress, its start was only *assumed*,
    /// and the offered date is earlier than the assumption. A start we watched
    /// happen is never moved, and a seed can only ever lengthen the session, so
    /// a wrong one cannot shorten "in 23 min" into a fiction.
    public mutating func seedSessionStart(_ date: Date) {
        guard externalConnected, !sessionStartIsObserved else { return }
        guard date < (sessionStart ?? .distantPast) else { return }
        sessionStart = date
    }

    /// Feed one status. Returns the event exactly once per charging session.
    ///
    /// - Parameter status: `nil` (device not in the snapshot) is a missed poll,
    ///   not an unplug, and changes nothing.
    @discardableResult
    public mutating func update(_ status: DeviceStatus?, kind: DeviceKind) -> Event? {
        guard let status else { return nil }
        let reading = status.reading

        guard reading.externalConnected else {
            // Off the charger: the session is over, and the next one may
            // notify again.
            externalConnected = false
            sessionStart = nil
            sessionStartIsObserved = false
            hasFired = false
            lastPercent = reading.percent
            return nil
        }

        if !externalConnected {
            // The cable just went in. Take the reading's own timestamp as the
            // session start rather than `now`: it is the moment we know about.
            //
            // Unless this is the first sample of all — then the device was
            // already charging when we started watching and this timestamp is
            // a guess that `seedSessionStart(_:)` may correct from the history.
            externalConnected = true
            sessionStart = reading.timestamp
            sessionStartIsObserved = lastPercent != nil
            hasFired = false
        }

        defer { lastPercent = reading.percent }

        guard reading.isCharging,
              !hasFired,
              let previous = lastPercent,
              previous < Self.threshold,
              reading.percent >= Self.threshold
        else { return nil }

        hasFired = true
        let elapsed = sessionStart.map { reading.timestamp.timeIntervalSince($0) }
        // `systemPowerInW` is `nil`, not `0`, when the device does not report
        // it — including on every partial reading — so the estimator's figure
        // is the fallback and "unknown" survives as `nil` all the way to the
        // notification body, which then omits that half.
        let watts = reading.systemPowerInW ?? status.chargingWatts
        return Event(
            kind: kind,
            deviceName: reading.name,
            percent: reading.percent,
            at: reading.timestamp,
            elapsed: (elapsed ?? 0) > 0 ? elapsed : nil,
            watts: watts,
            adapterWatts: (reading.adapterWatts ?? 0) > 0 ? reading.adapterWatts : nil
        )
    }
}
