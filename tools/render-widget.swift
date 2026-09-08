// Renders the widget layouts straight out of the extension's own sources with
// `ImageRenderer`, so `docs/widget-*.png` can never drift from the code.
//
//   swiftc -O -o /tmp/render-widget \
//       tools/render-widget.swift \
//       TandemApp/Sources/TandemWidget/{DevicePresentation,RingView,DayBars,MediumWidgetView,SmallWidgetView,LargeWidgetView,SampleSnapshot,SampleHistory,MonitorErrorShim}.swift \
//       BatteryCore/Sources/BatteryCore/{Models,TandemSnapshot,ChargeEstimator,Formatting}.swift \
//       BatteryCore/Sources/BatteryCore/History/HistoryModels.swift
//   /tmp/render-widget docs/widget-small.png small
//   /tmp/render-widget docs/widget-small-charging.png small-charging
//   /tmp/render-widget docs/widget-medium.png medium
//   /tmp/render-widget docs/widget-medium-charging.png medium-charging
//   /tmp/render-widget docs/widget-medium-states.png medium-states
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

// MARK: - The state matrix

/// One tile state from the approved matrix, built as the snapshot that produces
/// it rather than as a hand-set string: the sheet is only worth exporting if it
/// is what the real view does with real data.
func state(
    kind: DeviceKind,
    percent: Int,
    charging: Bool = false,
    external: Bool = false,
    fullyCharged: Bool = false,
    powerIn: Double? = nil,
    adapter: Int? = nil,
    load: Double? = nil,
    etaTo80: TimeInterval? = nil,
    timeToEmpty: TimeInterval? = nil,
    silentFor: TimeInterval = 0,
    now: Date
) -> DevicePresentation {
    let reading = BatteryReading(
        deviceID: "state-\(kind.rawValue)", kind: kind, name: "device",
        percent: percent, isCharging: charging, externalConnected: external,
        fullyCharged: fullyCharged,
        rawCurrentMAh: 0, rawMaxMAh: 0, designMAh: 0, voltageMV: 0, instantAmperageMA: 0,
        batteryPowerW: charging ? 60 : -13, systemPowerInW: powerIn,
        systemLoadW: load, adapterWatts: adapter,
        adapterDescription: nil, temperatureC: 0, cycleCount: 0,
        reportedTimeRemainingMinutes: nil, avgTimeToEmptyMinutes: nil,
        timestamp: now, transport: kind == .mac ? .local : .wifi
    )
    let status = DeviceStatus(
        reading: reading,
        etaTo80: etaTo80,
        timeToEmpty: timeToEmpty,
        chargingWatts: charging ? powerIn : nil,
        lastSeen: now.addingTimeInterval(-silentFor),
        // Silence is a run of *failed reads*, not an old reading, so the sample
        // has to carry both halves of the rule for the tile to draw it.
        unreachableSince: silentFor > 0 ? now.addingTimeInterval(-silentFor) : nil,
        failedAttempts: silentFor > 0 ? DeviceStatus.silenceAttempts : 0
    )
    return DevicePresentation(kind: kind, status: status, now: now)
}

/// `[90, 86, …]` + `"mmb…"` → twelve columns, the mock-up's own notation.
func columns(_ percents: [Int], _ states: String) -> [TileBar] {
    zip(percents, states).map { percent, letter in
        TileBar(percent: percent, state: letter == "c" ? .charging : (letter == "m" ? .mains : .battery))
    }
}

/// The four combinations from `docs/design/widget/Combos.dc.html`, as a 2 x 2
/// sheet of real medium widgets.
struct StatesSheet: View {
    let now: Date

    private let macDay = [90, 90, 90, 90, 90, 90, 86, 74, 60, 44, 30, 32]
    private let phoneDay = [62, 78, 92, 86, 80, 74, 68, 60, 54, 48, 42, 38]

    var body: some View {
        Grid(horizontalSpacing: 24, verticalSpacing: 22) {
            GridRow {
                cell("Both charging", bothCharging)
                cell("Mac on the wall, iPhone on battery", macMains)
            }
            GridRow {
                cell("Mac on battery, iPhone silent", macBattery)
                cell("Mac on hold, iPhone charged on the wire", macOnHold)
            }
        }
        .padding(24)
    }

    private var bothCharging: MediumWidgetView {
        MediumWidgetView(
            mac: state(kind: .mac, percent: 32, charging: true, external: true,
                       powerIn: 62, adapter: 140, etaTo80: 27 * 60, now: now),
            phone: state(kind: .iphone, percent: 38, charging: true, external: true,
                         powerIn: 36, adapter: 45, etaTo80: 14 * 60, now: now),
            bars: DayBars(mac: columns(macDay, "mmmmmmbbbbbc"),
                          phone: columns(phoneDay, "ccbbbbbbbbbc"))
        )
    }

    private var macMains: MediumWidgetView {
        MediumWidgetView(
            mac: state(kind: .mac, percent: 90, external: true, powerIn: 13, adapter: 140, now: now),
            phone: state(kind: .iphone, percent: 38, timeToEmpty: 13 * 3600 + 21 * 60, now: now),
            bars: DayBars(mac: columns(Array(repeating: 90, count: 12), "mmmmmmmmmmmm"),
                          phone: columns(phoneDay, "ccbbbbbbbbbb"))
        )
    }

    private var macBattery: MediumWidgetView {
        MediumWidgetView(
            mac: state(kind: .mac, percent: 32, load: 13,
                       timeToEmpty: 4 * 3600 + 19 * 60, now: now),
            // Eleven minutes of failed reads: past the ten-minute window and
            // over the two-attempt floor, so the tile dims, takes the
            // exclamation mark and says when the silence began.
            phone: state(kind: .iphone, percent: 38, timeToEmpty: 13 * 3600 + 21 * 60,
                         silentFor: 11 * 60, now: now),
            bars: DayBars(mac: columns(macDay, "mmmmmmbbbbbb"),
                          phone: columns(phoneDay, "ccbbbbbbbbbb"))
        )
    }

    private var macOnHold: MediumWidgetView {
        MediumWidgetView(
            mac: state(kind: .mac, percent: 62, external: true, powerIn: 13, adapter: 140, now: now),
            phone: state(kind: .iphone, percent: 100, external: true, fullyCharged: true,
                         adapter: 45, now: now),
            bars: DayBars(
                mac: columns([70, 68, 66, 64, 62, 62, 62, 62, 62, 62, 62, 62], "bbbbbmmmmmmm"),
                phone: columns([62, 78, 92, 100, 100, 100, 100, 100, 100, 100, 100, 100], "cccmmmmmmmmm")
            )
        )
    }

    private func cell(_ title: String, _ widget: MediumWidgetView) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.black.opacity(0.55))
            widget
                .frame(width: 360, height: 170)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color(white: 0.23))
                )
                .environment(\.colorScheme, .dark)
        }
    }
}

@main
struct RenderWidget {

    /// The day with its newest column replaced by where the tile actually is.
    static func landing(_ bars: [TileBar], on percent: Int?) -> [TileBar] {
        guard !bars.isEmpty else { return bars }
        var bars = bars
        bars[bars.count - 1] = TileBar(percent: percent, state: .charging)
        return bars
    }

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write(Data("usage: render-widget <out.png> small|small-charging|medium|medium-charging|medium-states|large\n".utf8))
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
        case "medium-states":
            // The whole matrix on one sheet, on the mock-up's grey, so the four
            // combinations can be read against `Combos.dc.html` side by side.
            render(StatesSheet(now: now).background(Color(white: 0.55)),
                   size: CGSize(width: 816, height: 452), scale: 2, to: out)
        case "large":
            // The chart is the point of this family and it is drawn in the
            // colours a real widget gets on the desktop, so the large export is
            // the one rendered dark; 360x376 is the large rect with the same
            // 16 pt of framing the other exports use.
            render(LargeWidgetView(mac: mac, phone: phone, history: SampleHistory.make(now: now), now: now),
                   size: CGSize(width: 360, height: 376), scale: 2, to: out, dark: true)
        default:
            var bars = DayBars(history: SampleHistory.make(now: now), now: now)
            if variant.hasSuffix("-charging") {
                // The stress pair is a different snapshot from the sample day,
                // so the newest column is corrected to agree with the tile: a
                // widget picture whose bolt and whose last bar disagreed about
                // the same two minutes would be a bug report, not a render.
                bars.mac = Self.landing(bars.mac, on: mac.percent)
                bars.phone = Self.landing(bars.phone, on: phone.percent)
            }
            render(MediumWidgetView(mac: mac, phone: phone, bars: bars),
                   size: CGSize(width: 360, height: 170), scale: 3, to: out)
        }
    }
}
