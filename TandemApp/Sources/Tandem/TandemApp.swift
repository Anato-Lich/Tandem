import SwiftUI
import AppKit
import ServiceManagement
import UserNotifications
import os
import BatteryCore

@main
struct TandemApp: App {

    @State private var model = TandemModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow

    /// Set once registration with `SMAppService.mainApp` has been attempted,
    /// so the app only ever asks for the login item once — after that the
    /// user's own choice (via the footer's Launch at login toggle) is
    /// authoritative.
    @AppStorage("didRegisterLoginItem") private var didRegisterLoginItem = false

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environment(model)
        } label: {
            // The label is always instantiated (it *is* the menu-bar item),
            // unlike the popover content which is lazy — so this is where we
            // kick off polling at launch, and where the summary window is
            // opened from: `openWindow` needs a view inside a scene, and this
            // is the one view that is guaranteed to exist.
            MenuBarLabelView()
                .environment(model)
                .task {
                    delegate.model = model
                    model.start()
                    registerLoginItemIfNeeded()
                }
                .onChange(of: model.summaryRequest?.token) { _, token in
                    guard token != nil else { return }
                    // A request that found the window already on screen only
                    // moves the selection inside it (item 1a). `openWindow` on
                    // an open window is not a no-op — it orders it front — so
                    // it is skipped rather than relied on.
                    guard model.summaryRequest?.raisesWindow ?? true else { return }
                    openWindow(id: Self.summaryWindowID)
                }
        }
        .menuBarExtraStyle(.window)

        // The summary window: both devices' history side by side, opened from a
        // widget tile (`tandem://summary/mac` | `/iphone`), from a popover row,
        // or from the popover menu. Not resizable — every number in it is laid
        // out for this one size, and nothing in it scrolls.
        Window("Tandem", id: Self.summaryWindowID) {
            SummaryWindowView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        // The two-column layout's size, which is also the default setting; the
        // window itself resizes to `SummaryLayout.size` when the setting says
        // otherwise (`SummaryWindowView.WindowConfigurator`).
        .defaultSize(width: SummaryWindowView.defaultSize.width, height: SummaryWindowView.defaultSize.height)
    }

    static let summaryWindowID = "summary"

    private func registerLoginItemIfNeeded() {
        guard !didRegisterLoginItem else { return }
        didRegisterLoginItem = true
        do {
            try SMAppService.mainApp.register()
        } catch {
            os_log("Failed to register login item: %{public}@", String(describing: error))
        }
    }
}

/// Handles `tandem://` URLs — the only thing a widget can do when it is tapped.
///
/// `Window` scenes have no `onOpenURL` of their own until they exist, and this
/// app has no `WindowGroup` at all, so the URL is taken here (AppKit calls this
/// for the `GURL` Apple event regardless of which scenes are open) and turned
/// into a `TandemModel.requestSummary`, which the menu-bar label's `onChange`
/// then turns into `openWindow`.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    /// Set by the menu-bar label's `task` as soon as the app has a model. A URL
    /// that arrives before then (a launch *caused* by a widget tap) is held and
    /// replayed.
    @MainActor
    var model: TandemModel? {
        didSet {
            guard pendingSummary else { return }
            pendingSummary = false
            model?.requestSummary(device: pendingDevice)
        }
    }

    /// A `tandem://summary` that arrived before the model existed — a launch
    /// *caused* by a widget click — and the device it named, if any.
    @MainActor private var pendingSummary = false
    @MainActor private var pendingDevice: DeviceKind?

    private static let log = Logger(subsystem: "dev.tandem", category: "url")
    private static let notifyLog = Logger(subsystem: "dev.tandem", category: "notify")

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    /// The delegate has to be in place before any notification can be
    /// delivered, which is why it is set here rather than by whatever posts
    /// one (`ChargeNotifier`).
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Notification taps

    /// A tap on "iPhone reached 80 %" opens the summary at that device — the
    /// same `tandem://summary/<device>` a widget tile uses, through the same
    /// handler, so the already-open-window rule (item 1a) applies unchanged.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // The delegate callback is not main-actor isolated and `self` is not
        // `Sendable`, so the hop goes through the shared application rather
        // than carrying `self` across.
        await Self.open(response.notification.request.content.userInfo["url"] as? String)
    }

    @MainActor
    private static func open(_ string: String?) {
        guard let string, let url = URL(string: string) else { return }
        notifyLog.notice("notification tapped: \(string, privacy: .public)")
        // An agent app is never "active" on its own; without this the summary
        // window opens behind whatever the person was looking at.
        NSApplication.shared.activate()
        (NSApplication.shared.delegate as? AppDelegate)?.handle(url)
    }

    /// This is an `LSUIElement` agent, so it is never frontmost in the sense
    /// the default suppression rule means — show the banner regardless.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    @MainActor
    func handle(_ url: URL) {
        guard url.scheme == "tandem" else { return }
        // `tandem://summary`, and `tandem://summary/mac` | `/iphone` for the
        // column to highlight.
        let host = url.host()
        guard host == "summary" else {
            Self.log.debug("ignoring \(url.absoluteString, privacy: .public)")
            return
        }
        let path = url.pathComponents.first { $0 != "/" }
        let device = path.flatMap { DeviceKind(rawValue: $0) }
        Self.log.notice("opened \(url.absoluteString, privacy: .public)")
        if let model {
            model.requestSummary(device: device)
        } else {
            pendingSummary = true
            pendingDevice = device
        }
    }
}
