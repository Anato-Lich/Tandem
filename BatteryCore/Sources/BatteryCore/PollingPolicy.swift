import Foundation

/// How visible the readout currently is, which is what decides how often the
/// *phone* may be dialled. See NOTES.md §14.
///
/// The phone poll is the only expensive thing in this package: it opens a TCP
/// connection and a TLS session, which wakes `lockdownd` on the phone and
/// its radio with it. The Mac read is an in-process IOKit call and is free, so
/// it is only slowed (never stopped) by this.
public enum ActivityLevel: String, Sendable, Codable, Equatable, CaseIterable, Comparable {
    /// The display is asleep or the screen is locked: nobody can see anything,
    /// so the phone is not polled at all.
    case hidden
    /// The app is running with nothing of it on screen but the menu-bar label.
    case background
    /// A widget asked for a timeline recently (see `WidgetActivityMarker`).
    case widgetVisible
    /// The popover is open — somebody is looking right now.
    case popoverOpen

    /// Ordering, so `max(_:_:)` and `<` mean "more visible".
    public var rank: Int {
        switch self {
        case .hidden: return 0
        case .background: return 1
        case .widgetVisible: return 2
        case .popoverOpen: return 3
        }
    }

    public static func < (lhs: ActivityLevel, rhs: ActivityLevel) -> Bool {
        lhs.rank < rhs.rank
    }

    /// False only for `.hidden`, where the phone is left alone entirely.
    public var pollsPhone: Bool { self != .hidden }
}

/// How often to poll a device, given what we last saw and who is looking.
///
/// Pure and deterministic so the schedule can be unit tested without sleeping.
public struct PollingPolicy: Sendable, Equatable {

    /// What the last poll told us about a device.
    public enum State: String, Sendable, Equatable, CaseIterable {
        case charging
        case discharging
        case unreachable
    }

    /// The `.widgetVisible` cadence, and the Mac's cadence at every level but
    /// `.hidden`. Named without a level prefix because they predate
    /// `ActivityLevel` and are still what a caller that knows nothing about
    /// activity gets from `nextDelay(state:)`.
    public var chargingInterval: TimeInterval
    public var dischargingInterval: TimeInterval
    /// The `.background` cadence: menu bar only, nobody is looking at a number.
    public var backgroundChargingInterval: TimeInterval
    public var backgroundDischargingInterval: TimeInterval
    /// The `.popoverOpen` cadence.
    public var popoverInterval: TimeInterval
    /// While `.hidden` the Mac still gets a sanity read this often, so the
    /// menu-bar label and the snapshot file are not hours old on wake. The
    /// phone gets nothing.
    public var hiddenSanityInterval: TimeInterval
    /// Backoff ladder used while unreachable; the last entry is the cap.
    public var unreachableBackoff: [TimeInterval]

    public init(
        chargingInterval: TimeInterval = 60,
        dischargingInterval: TimeInterval = 120,
        unreachableBackoff: [TimeInterval] = [60, 120, 300, 600],
        backgroundChargingInterval: TimeInterval = 120,
        backgroundDischargingInterval: TimeInterval = 300,
        popoverInterval: TimeInterval = 15,
        hiddenSanityInterval: TimeInterval = 600
    ) {
        precondition(!unreachableBackoff.isEmpty, "backoff ladder must not be empty")
        self.chargingInterval = chargingInterval
        self.dischargingInterval = dischargingInterval
        self.unreachableBackoff = unreachableBackoff
        self.backgroundChargingInterval = backgroundChargingInterval
        self.backgroundDischargingInterval = backgroundDischargingInterval
        self.popoverInterval = popoverInterval
        self.hiddenSanityInterval = hiddenSanityInterval
    }

    /// Delay before the next poll, ignoring activity.
    ///
    /// This is the pre-activity API and is unchanged: it is what the Mac loop
    /// uses at every level but `.hidden`, and what a caller with no UI (the
    /// CLI) gets.
    ///
    /// - Parameters:
    ///   - state: outcome of the poll that just happened.
    ///   - consecutiveFailures: how many polls in a row have failed (1 for the
    ///     first failure). Ignored unless `state == .unreachable`.
    ///   - externalEvent: set when a plug/unplug or attach/detach notification
    ///     arrived; the caller should poll immediately.
    public func nextDelay(
        state: State,
        consecutiveFailures: Int = 0,
        externalEvent: Bool = false
    ) -> TimeInterval {
        if externalEvent { return 0 }
        switch state {
        case .charging:
            return chargingInterval
        case .discharging:
            return dischargingInterval
        case .unreachable:
            return backoff(consecutiveFailures)
        }
    }

    /// The unreachable ladder's value for `consecutiveFailures`, capped at its
    /// last entry. A zeroth failure is treated as the first step.
    public func backoff(_ consecutiveFailures: Int) -> TimeInterval {
        let step = max(1, consecutiveFailures)
        return unreachableBackoff[min(step - 1, unreachableBackoff.count - 1)]
    }

    /// The steady-state phone cadence for a level, ignoring failures.
    ///
    /// `.unreachable` is treated as the level's slower (discharging) figure,
    /// since a phone we cannot reach tells us nothing about its plug state.
    public func phoneInterval(level: ActivityLevel, state: State) -> TimeInterval? {
        switch level {
        case .hidden:
            return nil
        case .popoverOpen:
            return popoverInterval
        case .widgetVisible:
            return state == .charging ? chargingInterval : dischargingInterval
        case .background:
            return state == .charging ? backgroundChargingInterval : backgroundDischargingInterval
        }
    }

    /// Delay before the next **phone** poll.
    ///
    /// `nil` means *do not poll at all* — only `.hidden` produces it. The
    /// caller is expected to sleep on its wake signal instead and re-ask once
    /// something happens.
    ///
    /// While unreachable the ladder applies, but it is reconciled with the
    /// level rather than overriding it: at `.background` a phone that is not
    /// answering is retried no more often than the 300 s cadence it would have
    /// had anyway (`max`), while at `.popoverOpen` the 15 s cadence still wins
    /// (`min`) because somebody is watching a spinner. Any external event
    /// short-circuits all of it.
    public func phoneDelay(
        level: ActivityLevel,
        state: State,
        consecutiveFailures: Int = 0,
        externalEvent: Bool = false
    ) -> TimeInterval? {
        guard let interval = phoneInterval(level: level, state: state) else { return nil }
        if externalEvent { return 0 }
        guard state == .unreachable else { return interval }
        let ladder = backoff(consecutiveFailures)
        return level == .popoverOpen ? min(ladder, interval) : max(ladder, interval)
    }

    /// The closest together two **event-driven** phone reads may be at this
    /// level: the fastest cadence the level would ever use on its own.
    ///
    /// Without this the policy leaks. NOTES.md §5 measured the phone dropping
    /// in and out of usbmuxd's device list every few tens of seconds over
    /// Wi-Fi, and every re-appearance is an attach event; unfloored, a phone
    /// nobody is looking at is polled as often as it flaps, which is the ~1400
    /// requests a day this whole thing exists to remove. An event still brings
    /// the next read *forward* — it just cannot make the phone busier than the
    /// level's own fastest cadence.
    ///
    /// High-value events (a USB cable, a pairing, an explicit
    /// `requestRefresh()`) bypass it; see `TandemMonitor`.
    public func eventFloor(level: ActivityLevel) -> TimeInterval? {
        switch level {
        case .hidden: return nil
        case .background: return backgroundChargingInterval
        case .widgetVisible: return chargingInterval
        case .popoverOpen: return popoverInterval
        }
    }

    /// Delay before the next **Mac** poll. Never `nil`: the read is an IOKit
    /// call that costs nothing, so `.hidden` only slows it to
    /// `hiddenSanityInterval`.
    public func macDelay(
        level: ActivityLevel,
        state: State,
        consecutiveFailures: Int = 0,
        externalEvent: Bool = false
    ) -> TimeInterval {
        if externalEvent { return 0 }
        guard level != .hidden else { return hiddenSanityInterval }
        return nextDelay(state: state, consecutiveFailures: consecutiveFailures)
    }

    /// Convenience: derive the state from a reading.
    public static func state(for reading: BatteryReading) -> State {
        reading.isCharging ? .charging : .discharging
    }
}

extension ActivityLevel {

    /// The floor a widget's timeline breadcrumb puts under the activity level.
    ///
    /// Pure, so the marker logic is unit tested without a widget, a container
    /// or a clock: a fresh marker means a widget asked for a timeline within
    /// the window and is therefore on somebody's desktop or in their
    /// Notification Center, which is `.widgetVisible`. Anything else is
    /// `.background`.
    public static func floor(
        marker: WidgetActivityMarker?,
        now: Date = Date(),
        window: TimeInterval = WidgetActivityMarker.freshnessWindow
    ) -> ActivityLevel {
        guard let marker, marker.isFresh(now: now, within: window) else { return .background }
        return .widgetVisible
    }

    /// Combine an explicitly signalled level with a floor discovered elsewhere
    /// (the widget marker).
    ///
    /// `.hidden` always wins: if the display is asleep or the screen is locked
    /// then no widget is visible either, whatever its last timeline request
    /// says. Otherwise the more visible of the two applies.
    public func raised(to floor: ActivityLevel) -> ActivityLevel {
        self == .hidden ? .hidden : Swift.max(self, floor)
    }
}
