import Foundation
import Observation
import AppKit
import UserNotifications
import os
import BatteryCore

/// Ties `TandemMonitor` to the UI.
///
/// One instance for the whole app, owned by `TandemApp`. Runs on the main
/// actor so its published properties can be read directly by SwiftUI views.
///
/// Note on `TandemMonitor.run()` vs `TandemMonitor.snapshots()`: the brief for
/// this app said to "start `monitor.run()` in a Task and consume
/// `monitor.snapshots()`", but `snapshots()`'s doc comment says iterating the
/// stream *already* starts the polling loops (and cancelling the iteration
/// stops them). Calling `run()` separately as well would start a second,
/// redundant pair of poll loops racing the first. We only consume
/// `snapshots()`, which is the actual documented way to drive the monitor.
@MainActor
@Observable
final class TandemModel {

    private(set) var snapshot = TandemSnapshot()
    private(set) var lastMacError: String?
    private(set) var lastPhoneError: String?

    /// True while a Resync is running, so the menu item can say so. Cleared by
    /// the resync itself or, at the latest, by `Self.resyncTitleTimeout`.
    private(set) var isResyncing = false

    /// Set every time something asks for the summary window — a widget tap
    /// (`tandem://summary`), a click on a popover row, or the popover menu's
    /// "Summary…". `MenuBarLabelView` watches it and calls `openWindow`; the
    /// window itself reads `device` to scroll to the right section.
    private(set) var summaryRequest: SummaryRequest?

    private let store: SnapshotStore
    private let widgetBridge = WidgetBridge()
    /// Every snapshot goes into the local history (SQLite, NOTES.md §15); a
    /// summary for the summary window and the future large widget is written
    /// next to the widget snapshot at most every ten minutes.
    ///
    /// Not private: the summary window reads it directly rather than opening a
    /// second `HistoryStore` on the same file (`SummaryWindowView`).
    let history = HistoryStore()
    private var lastSummaryWrite: Date = .distantPast
    nonisolated static let historySummaryURL: URL = WidgetBridge.snapshotURL
        .deletingLastPathComponent()
        .appendingPathComponent("history-summary.json", isDirectory: false)
    private let widgetActivity = WidgetActivityProbe()
    private let monitor: TandemMonitor
    private let energyLog = Logger(subsystem: "dev.tandem", category: "energy")
    private var pollTask: Task<Void, Never>?
    private var activityTasks: [Task<Void, Never>] = []
    private var statsTask: Task<Void, Never>?

    /// The three things that decide the activity level, tracked separately
    /// because they arrive from three different notification centres and can
    /// overlap (the screen can lock while the popover is open).
    private var displayAsleep = false
    private var screenLocked = false
    private var popoverIsOpen = false

    /// One per device: the 80 %-while-charging watcher (`ChargeMilestone`,
    /// BatteryCore) and the notifications it produces.
    private var macMilestone = ChargeMilestone()
    private var phoneMilestone = ChargeMilestone()
    /// Devices whose current charging session has already had its start looked
    /// up in the history. Cleared when the cable comes out.
    private var seededSessions: Set<DeviceKind> = []
    private let notifier = ChargeNotifier()
    private var resyncTask: Task<Void, Never>?
    private var resyncTitleTask: Task<Void, Never>?
    /// How long the menu item may say "Resyncing…" before it goes back to
    /// normal, whatever the read is still doing.
    private static let resyncTitleTimeout: TimeInterval = 10

    /// The label the menu bar last rendered from. Rasterising costs an
    /// `ImageRenderer` pass, so `MenuBarLabelView` only redraws when this
    /// changes — not on every poll that moved a watt.
    var menuBarLabelState: MenuBarLabelState {
        MenuBarLabelState(mac: snapshot.mac, phone: snapshot.phone)
    }

    /// Cache for the rasterised menu-bar label, keyed by `menuBarLabelState`.
    let menuBarCache = MenuBarLabelCache()

    /// How often the energy counters are written to the log.
    private static let statsLogInterval: TimeInterval = 3600

    static let snapshotURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Tandem", isDirectory: true)
            .appendingPathComponent("snapshot.json", isDirectory: false)
    }()

    /// Polling/transport settings are no longer user-configurable (there is no
    /// Settings window) — these are the baked-in defaults the old Settings
    /// window used to expose.
    init() {
        self.store = SnapshotStore(url: Self.snapshotURL)
        self.monitor = TandemMonitor(
            store: store,
            configuration: TandemMonitor.Configuration(
                keepPhoneSessionAlive: false,
                preferNetworkTransport: false,
                useDirectClient: true,
                policy: PollingPolicy(
                    chargingInterval: 60,
                    dischargingInterval: 120
                )
            )
        )
    }

    /// Ask for the summary window, optionally pointed at one device.
    ///
    /// The token always moves, so a second request is always visible inside the
    /// window: the tabbed layout switches tab, the two-column one flashes the
    /// column. Whether the *window* reacts as well is decided here and once:
    /// a window that is already on screen is left alone — not activated, not
    /// re-positioned, not resized (item 1a) — and only a closed or miniaturised
    /// one is opened and raised.
    func requestSummary(device: DeviceKind? = nil) {
        let onScreen = SummaryWindowView.isOnScreen
        let token = (summaryRequest?.token ?? 0) + 1
        summaryRequest = SummaryRequest(device: device, token: token, raisesWindow: !onScreen)
        Self.summaryLog.notice(
            """
            summary requested device=\(device?.rawValue ?? "none", privacy: .public) \
            token=\(token, privacy: .public) onScreen=\(onScreen, privacy: .public) \
            raise=\(!onScreen, privacy: .public)
            """
        )
    }

    private static let summaryLog = Logger(subsystem: "dev.tandem", category: "summary")

    /// Idempotent: safe to call more than once (e.g. from a view that may
    /// re-appear).
    func start() {
        startPolling()
        startActivityObservers()
        startStatsLogging()
        Task { await notifier.requestAuthorizationIfNeeded() }
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        let monitor = self.monitor
        // The widget's own breadcrumb is what tells the scheduler a widget is
        // on screen; hand the monitor a reader for it before the loops start.
        let probe = widgetActivity
        Task {
            await monitor.setActivityFloorProvider { probe.level() }
            await monitor.setActivity(.background)
        }
        pollTask = Task { [weak self] in
            for await snap in await monitor.snapshots() {
                guard let self else { return }
                self.snapshot = snap
                self.lastMacError = await monitor.lastMacError
                self.lastPhoneError = await monitor.lastPhoneError
                await self.widgetBridge.publish(snap)
                await self.recordHistory(snap)
                await self.checkChargeMilestones(snap)
            }
        }
    }

    private func recordHistory(_ snap: TandemSnapshot) async {
        await HistoryRecorder.record(snap, into: history)
        guard Date().timeIntervalSince(lastSummaryWrite) >= 600 else { return }
        lastSummaryWrite = Date()
        do {
            _ = try await history.writeSummary(to: Self.historySummaryURL)
        } catch {
            Self.historyLog.error("summary write failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The two halves of the sleep marker. Both are fire-and-forget: a marker
    /// the store refuses to write costs one un-bridged session, never a poll.
    private func markSleep() {
        Task { [history] in
            do { try await history.recordSleep() } catch { Self.historyLog.error("sleep marker failed: \(String(describing: error), privacy: .public)") }
        }
    }

    private func markWake() {
        Task { [history] in
            do { try await history.recordWake() } catch { Self.historyLog.error("wake marker failed: \(String(describing: error), privacy: .public)") }
        }
    }

    nonisolated static let historyLog = Logger(subsystem: "dev.tandem", category: "history")

    /// Everything that tells us whether anybody can see the readout.
    ///
    /// `NSWorkspace` carries display sleep and system sleep;
    /// `DistributedNotificationCenter` carries the screen lock, which is a
    /// separate thing entirely (a locked Mac with the display awake is still
    /// showing nothing). Each of them ends in the same place: recompute the
    /// level and tell the monitor. See NOTES.md §14.
    private func startActivityObservers() {
        guard activityTasks.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        activityTasks = [
            observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.displayAsleep = true },
            observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.displayAsleep = false },
            // Sleep and wake are also written into the history, because a Mac
            // that sleeps on the charger otherwise leaves a hole longer than
            // `ChargeSessionBuilder.maximumGap` and one overnight charge gets
            // booked as two sessions (NOTES.md §15.7).
            observe(workspace, NSWorkspace.willSleepNotification) {
                $0.displayAsleep = true
                $0.markSleep()
            },
            // Waking is an event in its own right: read now, whatever the level
            // works out to be (the phone loop ignores it while still locked).
            observe(workspace, NSWorkspace.didWakeNotification) {
                $0.displayAsleep = false
                $0.markWake()
                $0.refresh()
            },
            observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.screenLocked = true },
            observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.screenLocked = false }
        ]
    }

    private func observe(
        _ center: NotificationCenter,
        _ name: Notification.Name,
        _ handler: @escaping @MainActor (TandemModel) -> Void
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await _ in center.notifications(named: name) {
                guard let self else { return }
                handler(self)
                self.applyActivity()
            }
        }
    }

    /// Once an hour, one line of energy accounting in the log:
    ///
    ///     log show --predicate 'subsystem == "dev.tandem" && category == "energy"' --last 2h
    private func startStatsLogging() {
        guard statsTask == nil else { return }
        let monitor = self.monitor
        let log = energyLog
        statsTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.statsLogInterval))
                guard !Task.isCancelled else { return }
                let stats = await monitor.stats
                log.notice("\(stats.summary(), privacy: .public)")
            }
        }
    }

    /// The level the world is in right now. `.hidden` beats everything: a
    /// locked or dark screen shows nothing, popover or not.
    private var activityLevel: ActivityLevel {
        if displayAsleep || screenLocked { return .hidden }
        if popoverIsOpen { return .popoverOpen }
        // `.widgetVisible` is not decided here: the monitor raises `.background`
        // to it whenever the widget's breadcrumb is fresh, which it re-checks
        // on every scheduling decision rather than once here.
        return .background
    }

    private func applyActivity() {
        let level = activityLevel
        Task { [monitor] in await monitor.setActivity(level) }
    }

    /// Wake both poll loops right away — called on wake-from-sleep and once
    /// each time the popover opens. Cheaper than the old `pollOnce()` (which
    /// raced a second, one-shot pair of reads alongside the running loops) —
    /// `requestRefresh()` reuses the loops that are already running and is
    /// coalesced by `AsyncSignal`, so calling it repeatedly in quick
    /// succession produces one extra poll, not one per call. The refreshed
    /// snapshot arrives through the `snapshots()` stream `start()` already
    /// consumes.
    func refresh() {
        Task { [weak self] in
            await self?.monitor.requestRefresh()
        }
    }

    /// The footer menu's "Resync": forget where the phone lives, drop the
    /// session, clear the backoff and go looking again (`TandemMonitor.resync`).
    ///
    /// `refresh()` is the cheap sibling — poll sooner, same address. This is
    /// the one for a phone that has changed network, been re-paired or simply
    /// stopped answering the address on file.
    func resync() {
        guard resyncTask == nil else { return }
        isResyncing = true
        // The title is capped independently of the read: a resync that runs
        // into its 8 s read budget plus discovery must not leave the menu
        // saying "Resyncing…" indefinitely. Cancelled the moment the read
        // returns, so it can never clear a *later* resync's title.
        resyncTitleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.resyncTitleTimeout))
            guard !Task.isCancelled else { return }
            self?.isResyncing = false
        }
        resyncTask = Task { [weak self, monitor] in
            let outcome = await monitor.resync()
            Self.notifyLog.notice("\(outcome.summary, privacy: .public)")
            guard let self else { return }
            self.resyncTitleTask?.cancel()
            self.resyncTitleTask = nil
            self.isResyncing = false
            self.resyncTask = nil
        }
    }

    // MARK: - The 80 % notification

    /// Feed both devices' statuses to their `ChargeMilestone` and post whatever
    /// comes back. See `ChargeMilestone` for the rule; everything time- or
    /// device-dependent lives there, and nothing here decides anything.
    private func checkChargeMilestones(_ snap: TandemSnapshot) async {
        await check(snap.mac, kind: .mac)
        await check(snap.phone, kind: .iphone)
    }

    private func check(_ status: DeviceStatus?, kind: DeviceKind) async {
        var milestone = (kind == .mac) ? macMilestone : phoneMilestone
        let event = milestone.update(status, kind: kind)
        if !milestone.externalConnected { seededSessions.remove(kind) }
        store(milestone, kind: kind)

        if let event {
            Self.notifyLog.notice(
                """
                milestone \(kind.rawValue, privacy: .public) \(event.percent, privacy: .public) % \
                elapsed=\(event.elapsed.map { String(Int($0)) } ?? "unknown", privacy: .public) s \
                watts=\(event.watts.map { String(format: "%.1f", $0) } ?? "unknown", privacy: .public)
                """
            )
            await notifier.post(event)
        }

        // The app can be launched into a charge that started an hour ago, in
        // which case the first sample we saw is not the session's start. The
        // history knows the real one, so look it up once per session — before
        // any crossing can happen, since a crossing needs a previous sample.
        guard milestone.externalConnected,
              !milestone.sessionStartIsObserved,
              !seededSessions.contains(kind),
              let deviceID = status?.reading.deviceID
        else { return }
        seededSessions.insert(kind)
        guard let start = await openSessionStart(device: deviceID) else { return }
        // Re-read across the await rather than writing back the copy taken
        // before it; `ChargeMilestone` is a value type and the local one is a
        // snapshot of state as it stood a database read ago.
        var latest = (kind == .mac) ? macMilestone : phoneMilestone
        latest.seedSessionStart(start)
        store(latest, kind: kind)
    }

    private func store(_ milestone: ChargeMilestone, kind: DeviceKind) {
        switch kind {
        case .mac: macMilestone = milestone
        case .iphone: phoneMilestone = milestone
        }
    }

    /// The start of this device's charging session as the history store has it,
    /// if that session is still open. `nil` when the history has nothing, which
    /// is the ordinary case on a first run.
    private func openSessionStart(device: String) async -> Date? {
        do {
            let sessions = try await history.sessions(device: device, limit: 1)
            guard let latest = sessions.first, latest.end == nil else { return nil }
            return latest.start
        } catch {
            Self.notifyLog.error("session lookup failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    nonisolated static let notifyLog = Logger(subsystem: "dev.tandem", category: "notify")

    /// Called each time the popover opens: raises the activity level to
    /// `.popoverOpen` (15 s cadence) and polls immediately, so the popover
    /// shows a fresh reading and keeps refreshing quickly for as long as it
    /// stays open.
    func popoverDidOpen() async {
        popoverIsOpen = true
        await monitor.setActivity(activityLevel)
    }

    /// Called when the popover closes, so the phone drops back to the
    /// background (or widget-visible) cadence. `PopoverContentView` wires this
    /// to the popover content's `onDisappear`. If that never fires for some
    /// `MenuBarExtra` window state, `TandemMonitor` drops `.popoverOpen` by
    /// itself after `Configuration.boostDuration` (2 minutes), so a missed
    /// close can only cost two minutes of 15 s polling, never forever.
    func popoverDidClose() async {
        popoverIsOpen = false
        await monitor.setActivity(activityLevel)
    }

    /// True while the iPhone has been failing to answer for over ten minutes
    /// across at least two attempts (`DeviceStatus.isSilent(now:)`), or has
    /// never been seen at all — the same rule that lights the row's warning
    /// glyph, so the two can never disagree.
    ///
    /// The footer's "Resync" item is offered unconditionally and does not read
    /// this; a manual rediscovery is useful long before the app is prepared to
    /// call the phone silent.
    var phoneNeedsResync: Bool {
        guard let phone = snapshot.phone else { return true }
        return phone.isSilent(now: Date())
    }

    /// The activity level the monitor is actually scheduling at, for the
    /// footer/debug and for the hourly log line.
    func currentActivity() async -> ActivityLevel {
        await monitor.effectiveActivity()
    }

    /// Phone-request accounting since launch.
    func pollStats() async -> PollStats {
        await monitor.stats
    }
}

/// Posts the "reached 80 %" notification, and nothing else.
///
/// Authorisation is asked for **once**, provisionally: a provisional grant
/// needs no prompt and delivers quietly to Notification Centre, which is the
/// right register for a battery reaching a number. macOS promotes it to a full
/// grant the first time somebody keeps one. If the ask is refused there is
/// nothing to do about it and nothing to say — the log line is the whole
/// diagnosis:
///
///     log show --predicate 'subsystem == "dev.tandem" && category == "notify"' --last 1h
@MainActor
final class ChargeNotifier {

    /// `nil` until the ask has been answered.
    private var authorized: Bool?
    private var asking = false

    private var log: Logger { TandemModel.notifyLog }

    /// Ask once, provisionally. Safe to call repeatedly; only the first call
    /// reaches the notification centre.
    func requestAuthorizationIfNeeded() async {
        guard authorized == nil, !asking else { return }
        asking = true
        defer { asking = false }
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .provisional])
            authorized = granted
            let settings = await center.notificationSettings()
            log.notice(
                """
                authorization granted=\(granted, privacy: .public) \
                status=\(settings.authorizationStatus.rawValue, privacy: .public)
                """
            )
        } catch {
            authorized = false
            log.error("authorization failed: \(String(describing: error), privacy: .public)")
        }
    }

    func post(_ event: ChargeMilestone.Event) async {
        await requestAuthorizationIfNeeded()
        guard authorized == true else {
            log.notice("not authorized, dropping \(event.kind.rawValue, privacy: .public) 80 % notification")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = Self.title(for: event.kind)
        content.body = Self.body(for: event)
        content.sound = nil
        // Tapping opens the summary window at this device — the same URL a
        // widget tile uses, handled by the same `AppDelegate.handle(_:)`.
        content.userInfo = ["url": "tandem://summary/\(event.kind.rawValue)"]

        // One identifier per device: a second notification for the same phone
        // replaces the first rather than stacking, which cannot happen inside
        // one session anyway but can across a relaunch.
        let request = UNNotificationRequest(
            identifier: "dev.tandem.charged80.\(event.kind.rawValue)",
            content: content,
            trigger: nil
        )
        do {
            try await UNUserNotificationCenter.current().add(request)
            log.notice("posted \(event.kind.rawValue, privacy: .public): \(content.body, privacy: .public)")
        } catch {
            log.error("post failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func title(for kind: DeviceKind) -> String {
        switch kind {
        case .mac: return String(localized: "MacBook reached 80 %")
        case .iphone: return String(localized: "iPhone reached 80 %")
        }
    }

    /// `Charged to 80 % in 23 min · 36/45 W`, with either half dropped when it
    /// is unknown — never a "0 W" or an "in — min" standing in for one.
    ///
    /// The literal `%` is doubled in the format strings because they go through
    /// `String(format:)`; `% i` would otherwise be read as a conversion.
    static func body(for event: ChargeMilestone.Event) -> String {
        let time = event.elapsed.map { StatusFormatter.shortDuration($0) }
        let power = powerText(event)
        switch (time, power) {
        case let (time?, power?):
            return String(format: String(localized: "Charged to 80 %% in %1$@ · %2$@"), time, power)
        case let (time?, nil):
            return String(format: String(localized: "Charged to 80 %% in %1$@"), time)
        case let (nil, power?):
            return String(format: String(localized: "Charged to 80 %% · %1$@"), power)
        case (nil, nil):
            return String(localized: "Charged to 80 %")
        }
    }

    /// `36/45 W` — in over rated, exactly as the summary's adapter column reads
    /// it (`StatColumn.adapter`). Whole watts; a tenth of a watt has never
    /// changed anybody's mind.
    static func powerText(_ event: ChargeMilestone.Event) -> String? {
        switch (event.watts, event.adapterWatts) {
        case let (watts?, rated?): return "\(Int(watts.rounded()))/\(rated) W"
        case let (watts?, nil): return "\(Int(watts.rounded())) W"
        case let (nil, rated?): return "\(rated) W"
        case (nil, nil): return nil
        }
    }
}
