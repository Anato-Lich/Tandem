import SwiftUI
import AppKit
import os
import BatteryCore

/// The "summary" `Window` scene's content: the live snapshot for the headers,
/// `HistoryStore` for everything else, reloaded when the window opens and once a
/// minute for as long as it stays open.
///
/// The store is the app's own (`TandemModel.history`) rather than a second
/// `HistoryStore` on the same file: the file is WAL and a second connection
/// would be safe, but the app is already writing to it every poll and there is
/// no reason to pay for a second connection to read what the first one owns.
struct SummaryWindowView: View {
    @Environment(TandemModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [SummaryDevice] = []
    @State private var loadedAt = Date()
    /// Which of the two approved layouts to draw, set from the popover's
    /// "Summary layout" submenu (`FooterView`). Two windows' worth of geometry
    /// hangs off it, so the frame and the AppKit content size both follow it.
    @AppStorage(SummaryLayout.storageKey) private var layoutRaw = SummaryLayout.columns.rawValue

    /// How often the history is re-read while the window is open. The header's
    /// live percent comes from the snapshot and updates on its own.
    private static let refreshInterval: TimeInterval = 60

    /// The whole of whichever layout is on, with nothing to scroll. Fixed:
    /// every number in the window is laid out for exactly this much room
    /// (`SummaryLayout.size`, which `TandemApp` also uses for `defaultSize`).
    static let defaultSize = SummaryLayout.columns.size

    private var layout: SummaryLayout {
        SummaryLayout(rawValue: layoutRaw) ?? .columns
    }

    /// Stamped on the window by `WindowConfigurator` the first time it is
    /// configured, so `isOnScreen` can find it again among `NSApp.windows` —
    /// which also holds the menu-bar extra's own window and, once it has been
    /// opened and closed, this one with `isVisible == false`.
    static let windowIdentifier = NSUserInterfaceItemIdentifier("dev.tandem.summary")

    /// Is the summary window in front of the user *right now*?
    ///
    /// `TandemModel.requestSummary` asks before it records a request: a widget
    /// tile clicked while the window is already up must change the selection
    /// and nothing else — no activation, no `orderFront`, no resize, no
    /// recentring (item 1a). Miniaturised or closed both read as `false`, and
    /// those do want the window brought back.
    @MainActor
    static var isOnScreen: Bool {
        NSApp.windows.contains { $0.identifier == windowIdentifier && $0.isVisible }
    }

    var body: some View {
        SummaryContentView(
            devices: devices,
            now: loadedAt,
            layout: layout,
            highlight: model.summaryRequest?.device,
            highlightToken: model.summaryRequest?.token ?? 0
        )
        .frame(width: layout.size.width, height: layout.size.height)
        .background(WindowConfigurator(
            token: model.summaryRequest?.token ?? 0,
            raisesWindow: model.summaryRequest?.raisesWindow ?? true,
            contentSize: layout.size
        ))
        // Esc closes it, per the brief. `onExitCommand` is the documented hook;
        // the zero-sized cancel button behind it covers the case where nothing
        // in the content has taken focus yet.
        .onExitCommand { dismiss() }
        .overlay(alignment: .topLeading) {
            Button("", action: { dismiss() })
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.borderless)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .task(id: model.summaryRequest?.token) {
            // Reload on open (and on every fresh request), then keep it current
            // for as long as somebody is looking at it.
            while !Task.isCancelled {
                await reload()
                try? await Task.sleep(for: .seconds(Self.refreshInterval))
            }
        }
    }

    private func reload() async {
        let now = Date()
        devices = await model.summaryDevices(now: now)
        loadedAt = now
    }
}

/// Sets the summary window up, and pulls it to the front — but only for a
/// request that asked for that.
///
/// The app is `LSUIElement`, so it is not a foreground app and `openWindow`
/// alone puts the window up behind whatever the user is looking at.
/// `NSApp.activate` plus `makeKeyAndOrderFront` is what actually shows it.
/// A request that arrives while the window is already on screen carries
/// `raisesWindow == false` (`TandemModel.requestSummary`) and none of that is
/// done: the window keeps its place, its size and its key state, and the only
/// thing that changes is the selection inside it — the tab in the tabbed
/// layout, the column flash in the two-column one.
///
/// Everything here is also guarded against SwiftUI's own re-updates:
/// `updateNSView` runs on every state change in the window (the history
/// reloads once a minute), and re-activating the app on each of those would
/// steal focus from whatever the user had moved on to.
private struct WindowConfigurator: NSViewRepresentable {
    /// The request's token. Only a *new* one can raise the window.
    let token: Int
    /// Whether this request wants the window raised at all.
    let raisesWindow: Bool
    /// The size the chosen layout wants. `.windowResizability(.contentSize)`
    /// gets the window there on its own for a *new* window, but a window that
    /// is already up when the setting changes keeps its old frame, so the size
    /// is also set here — on the layout changing, not once at launch.
    let contentSize: CGSize

    private static let log = Logger(subsystem: "dev.tandem", category: "summary")

    @MainActor
    final class Coordinator {
        var configured = false
        var lastToken: Int?
        var lastSize: CGSize?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let coordinator = context.coordinator
        DispatchQueue.main.async { MainActor.assumeIsolated { configure(view, coordinator) } }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        DispatchQueue.main.async { MainActor.assumeIsolated { configure(view, coordinator) } }
    }

    @MainActor
    private func configure(_ view: NSView, _ coordinator: Coordinator) {
        guard let window = view.window else { return }

        if !coordinator.configured {
            coordinator.configured = true
            window.identifier = SummaryWindowView.windowIdentifier
            window.title = "Tandem"
            window.isMovableByWindowBackground = true
            window.standardWindowButton(.zoomButton)?.isEnabled = false
        }

        // The layout's size, applied when the layout actually changed. Doing
        // this unconditionally would fight a window the user has just moved.
        if coordinator.lastSize != contentSize {
            coordinator.lastSize = contentSize
            if window.contentView?.frame.size != contentSize {
                window.setContentSize(contentSize)
                recentreIfOffscreen(window)
            }
        }

        guard coordinator.lastToken != token else { return }
        coordinator.lastToken = token
        guard raisesWindow else {
            Self.log.notice("summary already on screen: token \(token, privacy: .public) changes the selection only")
            return
        }
        recentreIfOffscreen(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        Self.log.notice("summary raised for token \(token, privacy: .public)")
    }

    /// Put the window back on a screen somebody is looking at.
    ///
    /// `Window` remembers its frame across launches (`NSWindow Frame summary`
    /// in the app's defaults), *including* the screen it was on. Unplug that
    /// display — or resize the window past the edge of the one that is left,
    /// which the layout setting can do — and the restored frame is somewhere
    /// nobody can see: the window opens, `makeKeyAndOrderFront` succeeds, and
    /// there is nothing on screen. Nothing else in this app has a window to
    /// lose, so the recovery lives here rather than in a general helper.
    @MainActor
    private func recentreIfOffscreen(_ window: NSWindow) {
        let visible = NSScreen.screens.contains { $0.visibleFrame.intersects(window.frame) }
        guard !visible else { return }
        window.center()
    }
}

/// Why the summary window was asked for, and for which device.
///
/// The token is what makes a repeat request visible: opening a window that is
/// already open is a no-op, so every entry point bumps this and the window's
/// `WindowConfigurator` raises itself when it changes.
struct SummaryRequest: Equatable {
    var device: DeviceKind?
    var token: Int
    /// `false` when the summary window was already on screen as the request
    /// came in: the window is then left exactly where it is and only the
    /// selection follows the request (item 1a).
    var raisesWindow: Bool = true
}

extension TandemModel {

    /// Build one `SummaryDevice` per kind: the live status from the newest
    /// snapshot, the recorded history from the store, and the capacity trend
    /// where there is enough history for one.
    ///
    /// A device is matched to its history by `deviceID` first and by kind only
    /// as a fallback, so swapping phones shows the new phone's history rather
    /// than merging two.
    func summaryDevices(now: Date = Date()) async -> [SummaryDevice] {
        let snapshot = self.snapshot
        let summary = (try? await history.summary(now: now)) ?? HistorySummary(generatedAt: now, devices: [])

        var result: [SummaryDevice] = []
        for kind in [DeviceKind.mac, .iphone] {
            let status = kind == .mac ? snapshot.mac : snapshot.phone
            let entry = status.flatMap { summary.device($0.reading.deviceID) } ?? summary.device(kind: kind)
            var trend: CapacityTrend?
            if let entry {
                trend = try? await history.capacityTrend(device: entry.device)
            }
            result.append(SummaryDevice(kind: kind, status: status, history: entry, trend: trend))
        }
        return result
    }
}
