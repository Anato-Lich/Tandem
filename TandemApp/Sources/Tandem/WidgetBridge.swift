import Foundation
import WidgetKit
import BatteryCore
import os

/// Hands each fresh snapshot to the WidgetKit extension.
///
/// The usual channel — an App Group container both processes can open — needs a
/// team identifier, and this Mac has no codesigning identity at all
/// (`security find-identity -v -p codesigning` is empty), so an App Group
/// entitlement cannot be issued, let alone honoured. The way round it, the same
/// one AirBattery uses, inverts the relationship: the widget extension is
/// sandboxed and therefore has a container of its own, and this app is *not*
/// sandboxed (it has to talk to `/var/run/usbmuxd`), so it can simply write
/// into the extension's `Documents` directory. From inside the extension that
/// is just `FileManager`'s `.documentDirectory` — it never learns the path was
/// written from outside.
///
/// `~/Library/Application Support/Tandem/snapshot.json` keeps being written by
/// `TandemMonitor` as before; this is an additional copy, not a move.
@MainActor
final class WidgetBridge {

    nonisolated static let widgetBundleID = "dev.tandem.app.widget"

    /// `~/Library/Containers/dev.tandem.app.widget/Data/Documents/snapshot.json`.
    ///
    /// The container is created by the system the first time the extension
    /// runs, so on a fresh install this path's parents may not exist yet.
    /// `SnapshotStore.write` creates them with `withIntermediateDirectories`,
    /// which is deliberate: the file has to be there *before* the widget's
    /// first timeline request, or the first thing the user sees is an empty
    /// widget.
    nonisolated static let snapshotURL: URL = {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(widgetBundleID, isDirectory: true)
            .appendingPathComponent("Data/Documents", isDirectory: true)
            .appendingPathComponent("snapshot.json", isDirectory: false)
    }()

    /// `~/Library/Containers/dev.tandem.app.widget/Data/Documents/widget-activity.json`
    /// — the breadcrumb the *extension* writes each time WidgetKit asks it for
    /// a timeline, and the only evidence available that a widget is actually
    /// placed somewhere. Same container, same trick, opposite direction: the
    /// extension writes it and this (unsandboxed) app reads it.
    nonisolated static let activityMarkerURL: URL = {
        snapshotURL
            .deletingLastPathComponent()
            .appendingPathComponent(WidgetActivityMarker.fileName, isDirectory: false)
    }()

    /// A widget reload is a cross-process round trip; polls can be as frequent
    /// as every 30 s and a manual refresh can land on top of one. Never ask for
    /// more than one reload per this window.
    static let reloadThrottle: TimeInterval = 30

    /// Watts below this are not worth waking the extension for.
    static let wattTolerance: Double = 1

    private let store = SnapshotStore(url: WidgetBridge.snapshotURL)
    private let log = Logger(subsystem: "dev.tandem", category: "widget-bridge")
    private var lastReload: Date?
    /// What the widget was last *told* about, so an unchanged snapshot costs
    /// nothing. The file is still rewritten every poll; only the cross-process
    /// reload is skipped.
    private var lastReloadedSnapshot: TandemSnapshot?
    /// A change that arrived inside the throttle window and is waiting for it
    /// to end. Without this a reload was simply dropped and the widget kept
    /// its stale entry until the *next* poll produced another change — a
    /// device appearing at launch could sit as "no data" for a whole cycle.
    private var pendingReload: Task<Void, Never>?
    /// The newest snapshot handed to `publish`, which is also what is on disk.
    private var latestWritten: TandemSnapshot?

    /// Write, then (at most once per `reloadThrottle`) ask WidgetKit to redraw.
    /// The write always happens — dropping it would leave the widget showing an
    /// older reading than the file already on disk.
    func publish(_ snapshot: TandemSnapshot) async {
        latestWritten = snapshot
        do {
            try await store.write(snapshot)
        } catch {
            log.error("widget snapshot write failed: \(String(describing: error), privacy: .public)")
            return
        }

        let now = Date()
        guard Self.materiallyChanged(from: lastReloadedSnapshot, to: snapshot) else { return }

        // A device appearing or disappearing is worth interrupting the
        // throttle for: at launch the Mac is read from IOKit in a millisecond
        // and the phone takes a poll or two, and the gap between them is
        // exactly when somebody looks at the widget.
        let appeared = Self.appearedOrVanished(from: lastReloadedSnapshot, to: snapshot)
        if !appeared, let lastReload, now.timeIntervalSince(lastReload) < Self.reloadThrottle {
            // Hold it rather than drop it: the widget redraws the moment the
            // window is up, not at whatever the next material change happens
            // to be.
            let wait = Self.reloadThrottle - now.timeIntervalSince(lastReload)
            pendingReload?.cancel()
            pendingReload = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                await self?.flushPendingReload()
            }
            return
        }
        // Two gates, not one: at most one reload per 30 s *and* only when the
        // widget would actually draw something different. A poll that comes
        // back with the same percent, the same plug state and the same watts
        // has nothing to show, and the countdown to 80 % now runs off
        // `etaTo80At` inside the extension, so it does not need us either.
        pendingReload?.cancel()
        pendingReload = nil
        lastReload = now
        lastReloadedSnapshot = snapshot
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("reloaded widget timelines\(appeared ? " (device appeared)" : "")")
    }

    /// The deferred half of the throttle: the newest snapshot is already on
    /// disk, so this only has to tell WidgetKit to read it again.
    private func flushPendingReload() {
        pendingReload = nil
        lastReload = Date()
        lastReloadedSnapshot = latestWritten
        WidgetCenter.shared.reloadAllTimelines()
        log.debug("reloaded widget timelines (deferred)")
    }

    /// Did a device show up or go away entirely? That is the one change the
    /// throttle does not get to delay.
    static func appearedOrVanished(from old: TandemSnapshot?, to new: TandemSnapshot) -> Bool {
        guard let old else { return true }
        return (old.mac == nil) != (new.mac == nil) || (old.phone == nil) != (new.phone == nil)
    }

    /// Would the widget draw differently? Percent, charging/plugged state, a
    /// watt or more of power, or a device appearing or disappearing. Everything
    /// else — a fresher timestamp, a drifting ETA, a tenth of a watt — is
    /// invisible at widget size and is not worth a cross-process reload.
    static func materiallyChanged(from old: TandemSnapshot?, to new: TandemSnapshot) -> Bool {
        guard let old else { return true }
        return changed(old.mac, new.mac) || changed(old.phone, new.phone)
    }

    private static func changed(_ old: DeviceStatus?, _ new: DeviceStatus?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        // A device appearing or disappearing is the most visible change there is.
        case (nil, _), (_, nil): return true
        case let (old?, new?):
            if old.reading.percent != new.reading.percent { return true }
            if old.reading.isCharging != new.reading.isCharging { return true }
            if old.reading.externalConnected != new.reading.externalConnected { return true }
            if old.reading.fullyCharged != new.reading.fullyCharged { return true }
            if wattsChanged(old.chargingWatts, new.chargingWatts) { return true }
            if wattsChanged(old.reading.batteryPowerW, new.reading.batteryPowerW) { return true }
            if old.reading.adapterWatts != new.reading.adapterWatts { return true }
            return false
        }
    }

    private static func wattsChanged(_ old: Double?, _ new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (old?, new?): return abs(old - new) >= wattTolerance
        }
    }
}

/// Reads the widget's timeline breadcrumb for the scheduler.
///
/// `TandemMonitor` calls this on every scheduling decision, from its own actor
/// rather than the main one, so it is a plain `Sendable` class with a lock —
/// and it caches, because "every scheduling decision" includes both loops and
/// there is no point stat-ing the same file twice a second.
final class WidgetActivityProbe: @unchecked Sendable {

    /// How long a reading of the marker file is reused. Well under the marker's
    /// own 10-minute freshness window, so the level can never be more than this
    /// out of date.
    static let cacheWindow: TimeInterval = 15

    private let url: URL
    private let lock = NSLock()
    private var cachedLevel: ActivityLevel = .background
    private var checkedAt: Date?

    init(url: URL = WidgetBridge.activityMarkerURL) {
        self.url = url
    }

    /// `.widgetVisible` while a widget has asked for a timeline in the last ten
    /// minutes, `.background` otherwise. Never `.hidden`: a floor only ever
    /// raises the level, and `TandemMonitor` ignores it outright while hidden.
    func level(now: Date = Date()) -> ActivityLevel {
        lock.lock()
        defer { lock.unlock() }
        if let checkedAt, now.timeIntervalSince(checkedAt) < Self.cacheWindow {
            return cachedLevel
        }
        checkedAt = now
        cachedLevel = ActivityLevel.floor(marker: WidgetActivityMarker.read(from: url), now: now)
        return cachedLevel
    }
}
