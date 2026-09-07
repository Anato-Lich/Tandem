// Renders the widget layouts straight out of the extension's own sources with
// `ImageRenderer`, so `docs/widget-*.png` can never drift from the code.
//
//   swiftc -O -o /tmp/render-widget \
//       tools/render-widget.swift \
//       TandemApp/Sources/TandemWidget/{DevicePresentation,RingView,MediumWidgetView,SmallWidgetView,LargeWidgetView,SampleSnapshot,SampleHistory,MonitorErrorShim}.swift \
//       BatteryCore/Sources/BatteryCore/{Models,TandemSnapshot,ChargeEstimator,Formatting}.swift \
//       BatteryCore/Sources/BatteryCore/History/HistoryModels.swift
//   /tmp/render-widget docs/widget-small.png small
//   /tmp/render-widget docs/widget-small-charging.png small-charging
//   /tmp/render-widget docs/widget-medium.png medium
//   /tmp/render-widget docs/widget-medium-charging.png medium-charging
//   /tmp/render-widget docs/widget-large.png large
//
// Caveat: this draws the widget *content* only, on a plain sheet. The
// translucent material a placed widget sits on is painted by the macOS widget
// host (NotificationCenter), outside the extension entirely, and no offscreen
// renderer can reproduce it — see the note on `containerBackground` in
// TandemWidgetBundle.swift.

import AppKit
import SwiftUI

@MainActor
func render(_ view: some View, size: CGSize, scale: CGFloat, to path: String, dark: Bool = false) {
    let renderer = ImageRenderer(
        content: view
            // ImageRenderer draws a `Link` as the "not permitted" glyph; the
            // tiles render as themselves with the tap targets off.
            .environment(\.tileLinksEnabled, false)
            .frame(width: size.width, height: size.height)
            .background(dark ? Color(white: 0.13) : Color.white)
            .environment(\.colorScheme, dark ? .dark : .light)
    )
    renderer.scale = scale
    guard let cg = renderer.cgImage else {
        FileHandle.standardError.write(Data("render failed\n".utf8))
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(cg.width)x\(cg.height)")
}

/// Both devices on a 140 W brick: the busiest the medium tile ever gets, and
/// the one worth checking for collisions.
func chargingSample(now: Date = Date()) -> TandemSnapshot {
    func reading(kind: DeviceKind, name: String, percent: Int, watts: Double, adapter: Int) -> BatteryReading {
        BatteryReading(
            deviceID: "sample-\(kind.rawValue)", kind: kind, name: name,
            percent: percent, isCharging: true, externalConnected: true, fullyCharged: false,
            rawCurrentMAh: 0, rawMaxMAh: 0, designMAh: 0, voltageMV: 0, instantAmperageMA: 0,
            batteryPowerW: watts, systemPowerInW: nil, adapterWatts: adapter,
            adapterDescription: nil, temperatureC: 0, cycleCount: 0,
            reportedTimeRemainingMinutes: nil, avgTimeToEmptyMinutes: nil,
            timestamp: now, transport: kind == .mac ? .local : .wifi
        )
    }
    return TandemSnapshot(
        generatedAt: now,
        mac: DeviceStatus(
            reading: reading(kind: .mac, name: "MacBook Pro", percent: 62, watts: 62, adapter: 140),
            etaTo80: 9 * 60, chargingWatts: 62, lastSeen: now
        ),
        phone: DeviceStatus(
            reading: reading(kind: .iphone, name: "iPhone", percent: 64, watts: 36, adapter: 45),
            etaTo80: 14 * 60, chargingWatts: 36, lastSeen: now
        )
    )
}

@main
struct RenderWidget {

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: render-widget <out.png> small|small-charging|medium|medium-charging|large\n".utf8))
            exit(2)
        }
        let out = args[1]
        let variant = args[2]
        let now = Date()
        // `-charging` on any family swaps in the both-devices-on-a-brick pair.
        let snapshot = variant.hasSuffix("-charging") ? chargingSample(now: now) : SampleSnapshot.make(now: now)
        let mac = DevicePresentation(kind: .mac, status: snapshot.mac, now: now)
        let phone = DevicePresentation(kind: .iphone, status: snapshot.phone, now: now)

        // The real widget rects on macOS are 344x164 and 164x164; the extra
        // 16 pt here matches the framing the earlier exports used.
        switch variant {
        case "small", "small-charging":
            render(SmallWidgetView(mac: mac, phone: phone).padding(16),
                   size: CGSize(width: 170, height: 170), scale: 3, to: out)
        case "large":
            // The chart is the point of this family and it is drawn in the
            // colours a real widget gets on the desktop, so the large export is
            // the one rendered dark; 360x376 is the large rect with the same
            // 16 pt of framing the other exports use.
            render(LargeWidgetView(mac: mac, phone: phone, history: SampleHistory.make(now: now), now: now),
                   size: CGSize(width: 360, height: 376), scale: 2, to: out, dark: true)
        default:
            render(MediumWidgetView(mac: mac, phone: phone),
                   size: CGSize(width: 360, height: 170), scale: 3, to: out)
        }
    }
}
