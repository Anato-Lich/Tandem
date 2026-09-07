import SwiftUI
import AppKit
import ServiceManagement
import os
import BatteryCore

/// The `.window`-style MenuBarExtra popover: Mac row, iPhone row, footer.
struct PopoverContentView: View {
    @Environment(TandemModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            // One tick a minute, so the "to 80 %" countdown and the overdue
            // glyph move on their own. This is the whole point of
            // `DeviceStatus.etaTo80At`: the popover stays live while the phone
            // is dialled no more often than the activity level allows.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                VStack(alignment: .leading, spacing: 14) {
                    // A row is a button into the summary window, scrolled to
                    // that device — no chrome, no hover plate: the popover is
                    // two rows and a menu, and a click target that announced
                    // itself would be louder than the readout.
                    summaryLink(.mac) {
                        DeviceRowView(
                            kind: .mac,
                            status: model.snapshot.mac,
                            error: model.snapshot.macError,
                            now: context.date
                        )
                    }
                    summaryLink(.iphone) {
                        DeviceRowView(
                            kind: .iphone,
                            status: model.snapshot.phone,
                            error: model.snapshot.phoneError,
                            now: context.date
                        )
                    }
                }
            }
            .padding(14)

            Divider()

            FooterView()
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(width: 300)
        .task {
            model.start()
            model.refresh()
            await model.popoverDidOpen()
        }
        .onDisappear {
            Task { await model.popoverDidClose() }
        }
    }

    /// The whole row is the target, gaps included, so the click lands wherever
    /// the pointer happens to be inside it.
    private func summaryLink(_ kind: DeviceKind, @ViewBuilder content: () -> some View) -> some View {
        content()
            .contentShape(Rectangle())
            .onTapGesture { model.requestSummary(device: kind) }
            .help(String(localized: "Summary…"))
    }
}

/// Just the right-aligned overflow menu: "Resync" (only while the iPhone is
/// overdue), Launch-at-login toggle, Quit. Freshness is silent everywhere
/// else in the popover, so the footer carries no text of its own.
struct FooterView: View {
    @Environment(TandemModel.self) private var model

    /// The summary window's shape. It lives here rather than in a Settings
    /// window because there is no Settings window — this menu is where the
    /// app's two remaining preferences are, and the window reads the same
    /// `@AppStorage` key (`SummaryWindowView`).
    @AppStorage(SummaryLayout.storageKey) private var summaryLayout = SummaryLayout.columns.rawValue

    var body: some View {
        HStack {
            Spacer()

            Menu {
                Button(String(localized: "Summary…")) { model.requestSummary() }
                Menu(String(localized: "Summary layout")) {
                    Picker(String(localized: "Summary layout"), selection: $summaryLayout) {
                        ForEach(SummaryLayout.allCases) { layout in
                            Text(layout.title).tag(layout.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Divider()
                // Stays put while it runs, even once the phone answers and
                // `phoneNeedsResync` goes false: an item that vanished halfway
                // through would look like the click had failed.
                if model.phoneNeedsResync || model.isResyncing {
                    Button(model.isResyncing ? String(localized: "Resyncing…") : String(localized: "Resync")) {
                        model.resync()
                    }
                    .disabled(model.isResyncing)
                    Divider()
                }
                Toggle(String(localized: "Launch at login"), isOn: launchAtLoginBinding)
                Divider()
                Button(String(localized: "Quit Tandem")) { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    /// Reflects `SMAppService.mainApp.status` directly rather than caching it
    /// in `@AppStorage`, so the toggle always shows the real registration
    /// state (e.g. if the user later revokes it in System Settings).
    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { SMAppService.mainApp.status == .enabled },
            set: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    os_log("Failed to %{public}@ login item: %{public}@", enabled ? "register" : "unregister", String(describing: error))
                }
            }
        )
    }
}
