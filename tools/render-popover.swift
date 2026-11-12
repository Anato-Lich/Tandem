// Renders the popover's own rows (`DeviceRowView`, `StatColumnView`) and the
// menu-bar label's artwork (`MenuBarArtwork`) from synthetic data, so
// `docs/popover.png` and `docs/menubar.png` are made the same way the widget
// and summary shots are — `ImageRenderer` over the app's real SwiftUI views —
// rather than being screenshots of somebody's desktop.
//
// Build the same Foundation-only stub of BatteryCore `render-summary.swift`
// uses, then compile the two app views against it:
//
//   D=/tmp/tandem-render && mkdir -p $D
//   swiftc -O -emit-library -emit-module -module-name BatteryCore \
//       -o $D/libBatteryCore.dylib -emit-module-path $D/BatteryCore.swiftmodule \
//       BatteryCore/Sources/BatteryCore/{Models,TandemSnapshot,ChargeEstimator,Formatting,AirPods}.swift \
//       BatteryCore/Sources/BatteryCore/History/{HistoryModels,ChargeSessionBuilder}.swift \
//       TandemApp/Sources/TandemWidget/MonitorErrorShim.swift
//   swiftc -O -o $D/render-popover tools/render-popover.swift \
//       TandemApp/Sources/Tandem/{DeviceRowView,StatColumns,MenuBarArtwork}.swift \
//       -I $D -L $D -lBatteryCore
//   DYLD_LIBRARY_PATH=$D $D/render-popover docs/popover.png popover
//   DYLD_LIBRARY_PATH=$D $D/render-popover docs/menubar.png menubar
//
// Caveats, the same ones the other two renderers carry: this draws the
// *content* on a plain sheet. The popover's vibrant material, its arrow and its
// shadow come from AppKit, and the menu bar's own plate comes from the system;
// no offscreen renderer produces either. The footer's overflow control is drawn
// as the glyph it is — `Menu` renders as an empty box under `ImageRenderer` —
// so the plate is the popover minus its live menu. Strings come out in English:
// a command-line binary has no String Catalog to look them up in.

import AppKit
import SwiftUI
import BatteryCore

/// The stub module built above compiles `MonitorErrorShim.swift` — the
/// Foundation-only stand-in that carries the wire fields but not the real
/// enum's `localizedKey`, which `DeviceRowView` looks its wording up by. These
/// rows are rendered without an error, so this only has to exist and to keep
/// the real key shape.
extension MonitorError {
    var localizedKey: String { "tandem.error.\(kind)" }
}

let now = Date()

func reading(
    kind: DeviceKind,
    name: String,
    percent: Int,
    charging: Bool,
    external: Bool,
    watts: Double,
    adapter: Int?,
    systemPowerIn: Double? = nil,
    systemLoad: Double? = nil
) -> BatteryReading {
    BatteryReading(
        deviceID: "sample-\(kind.rawValue)", kind: kind, name: name,
        percent: percent, isCharging: charging, externalConnected: external, fullyCharged: false,
        rawCurrentMAh: 0, rawMaxMAh: 0, designMAh: 0, voltageMV: 0, instantAmperageMA: 0,
        batteryPowerW: watts, systemPowerInW: systemPowerIn, systemLoadW: systemLoad,
        adapterWatts: adapter,
        adapterDescription: nil, temperatureC: 0, cycleCount: 0,
        reportedTimeRemainingMinutes: nil, avgTimeToEmptyMinutes: nil,
        timestamp: now, transport: kind == .mac ? .local : .wifi
    )
}

/// The same pair `render-summary.swift` shows: a Mac on a 140 W brick, plugged
/// in and not charging, and a phone climbing towards 80 % on a 45 W adapter.
let macStatus = DeviceStatus(
    reading: reading(kind: .mac, name: "MacBook Pro", percent: 90, charging: false,
                     external: true, watts: 0, adapter: 140,
                     systemPowerIn: 32.0, systemLoad: 32.0),
    lastSeen: now
)

let phoneStatus = DeviceStatus(
    reading: reading(kind: .iphone, name: "iPhone", percent: 64, charging: true,
                     external: true, watts: 36, adapter: 45,
                     systemPowerIn: 36, systemLoad: 2.4),
    etaTo80: 14 * 60,
    chargingWatts: 36,
    lastSeen: now
)

let airpods = AirPodsStatus(name: "AirPods Pro", left: 82, right: 79, caseLevel: 64, lastHeard: now)

// MARK: - The popover plate

/// `PopoverContentView`'s layout — two rows in a 14 pt inset, a divider and the
/// overflow control — with the model-driven parts (the live `TimelineView`, the
/// tap targets, the `Menu`) left out, since none of them draws anything an
/// offscreen render can capture.
struct PopoverPlate: View {
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                DeviceRowView(kind: .mac, status: macStatus, error: nil, now: now)
                DeviceRowView(kind: .iphone, status: phoneStatus, error: nil, now: now)
                AirPodsRowView(status: airpods, now: now)
            }
            .padding(14)
            // The overflow control sits on the last row's line, no footer of its own.
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 10)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 300)
    }
}

// MARK: - Render

@MainActor
func render(_ view: some View, scale: CGFloat, to path: String, background: Color, dark: Bool) {
    let renderer = ImageRenderer(
        content: view
            .background(background)
            .environment(\.colorScheme, dark ? .dark : .light)
    )
    renderer.scale = scale
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    do {
        try data.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write(Data("write failed: \(error)\n".utf8))
        exit(1)
    }
    print("wrote \(path) \(cg.width)x\(cg.height)")
}

@main
struct RenderPopover {

    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(Data("usage: render-popover <out.png> popover|menubar\n".utf8))
            exit(2)
        }
        switch arguments[2] {
        case "menubar":
            // The label is a template image: black glyphs the system tints for
            // whichever menu bar they land in. Rendered here on the light plate
            // a light-appearance menu bar gives it, at the 2x a Retina bar
            // asks for.
            render(
                MenuBarArtwork(
                    mac: MenuBarLabelState.Chip(percent: 90, isCharging: false),
                    phone: MenuBarLabelState.Chip(percent: 64, isCharging: true)
                )
                .padding(.horizontal, 8)
                .padding(.vertical, 3),
                scale: 2, to: arguments[1], background: Color(white: 0.96), dark: false
            )
        default:
            render(PopoverPlate(), scale: 2, to: arguments[1],
                   background: Color(white: 0.13), dark: true)
        }
    }
}
