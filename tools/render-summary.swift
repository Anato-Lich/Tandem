// Renders the summary window's own SwiftUI views (`SummaryColumnsBody`,
// `SummaryTabsBody` and the pieces under them) from synthetic data, so
// `docs/summary-*.png` can never drift from the code that draws the real
// window.
//
// The app's views `import BatteryCore`, so this builds the Foundation-only half
// of the package as a stub module of that name first — the same four files the
// widget target compiles (project.yml), plus the two History files the summary
// reads, plus the widget's `MonitorError` shim. None of them touches
// libimobiledevice, so no Homebrew dylib is involved.
//
//   D=/tmp/tandem-render && mkdir -p $D
//   swiftc -O -emit-library -emit-module -module-name BatteryCore \
//       -o $D/libBatteryCore.dylib -emit-module-path $D/BatteryCore.swiftmodule \
//       BatteryCore/Sources/BatteryCore/{Models,TandemSnapshot,ChargeEstimator,Formatting}.swift \
//       BatteryCore/Sources/BatteryCore/History/{HistoryModels,ChargeSessionBuilder}.swift \
//       TandemApp/Sources/TandemWidget/MonitorErrorShim.swift
//   swiftc -O -o $D/render-summary tools/render-summary.swift \
//       TandemApp/Sources/Tandem/{SummaryContentView,SummaryDesign,SummaryColumnsView,SummaryTabsView,StatColumns}.swift \
//       -I $D -L $D -lBatteryCore
//   DYLD_LIBRARY_PATH=$D $D/render-summary docs/summary-columns.png columns
//   DYLD_LIBRARY_PATH=$D $D/render-summary docs/summary-tabs.png tabs
//   DYLD_LIBRARY_PATH=$D $D/render-summary docs/summary-columns-empty.png columns-empty
//
// The sheet is each layout's own window size (`SummaryLayout.size`, 924 x 640
// and 480 x 640), so what comes out is the whole window rather than a strip.
//
// Caveat, the same one `render-widget.swift` carries: this draws the window's
// *content* on a plain sheet. The window's own material, shadow and title bar
// come from AppKit and no offscreen renderer produces them. Strings come out in
// English — a command-line binary has no String Catalog to look them up in.

import AppKit
import SwiftUI
import BatteryCore

// MARK: - Synthetic devices

let now = Date()
let calendar = Calendar.current

/// A 24 h series from keyframes, sampled every 15 minutes exactly the way
/// `HistoryStore` buckets it (96 points, NOTES.md §15.4).
func series(_ keyframes: [(hoursAgo: Double, percent: Double, charging: Bool)]) -> [SeriesPoint] {
    let frames = keyframes.sorted { $0.hoursAgo > $1.hoursAgo }
    return (0..<96).map { step in
        let hoursAgo = 24 - Double(step) * 0.25
        let t = now.addingTimeInterval(-hoursAgo * 3600)
        var percent = frames.first?.percent ?? 0
        var charging = frames.first?.charging ?? false
        for (index, frame) in frames.enumerated() where frame.hoursAgo >= hoursAgo {
            guard index + 1 < frames.count else { percent = frame.percent; charging = frame.charging; break }
            let next = frames[index + 1]
            let span = frame.hoursAgo - next.hoursAgo
            let progress = span > 0 ? (frame.hoursAgo - hoursAgo) / span : 0
            percent = frame.percent + (next.percent - frame.percent) * min(1, max(0, progress))
            charging = frame.charging
        }
        return SeriesPoint(t: t, percent: Int(percent.rounded()), isCharging: charging)
    }
}

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

/// Hours between a moment and `now`, so the synthetic series can be pinned to
/// the very session times the "last charge" block prints.
func hoursAgo(_ date: Date) -> Double { now.timeIntervalSince(date) / 3600 }

let midnight = calendar.startOfDay(for: now)
/// 22:04 yesterday → 02:31 today, 80 % at 01:12: the overnight charge.
let macSessionStart = midnight.addingTimeInterval(-2 * 3600 + 4 * 60)
let macSessionEnd = midnight.addingTimeInterval(2 * 3600 + 31 * 60)
let macReached80 = midnight.addingTimeInterval(1 * 3600 + 12 * 60)
/// On the charger since 17:18-ish and still climbing.
let phoneSessionStart = now.addingTimeInterval(-2 * 3600 - 12 * 60)

/// A Mac on a 140 W brick at 90 %, plugged in and *not* charging — the state
/// that used to render "draw 0 W", and the one the system/adapter tiles exist
/// for. The numbers are the ones in `Fixtures/mac-plugged-not-charging.plist`:
/// SystemLoad and SystemPowerIn both 13307 mW, AdapterDetails.Watts 140,
/// Amperage 0 (so `batteryPowerW` is 0 and says nothing).
let macStatus = DeviceStatus(
    reading: reading(kind: .mac, name: "MacBook Pro", percent: 90, charging: false,
                     external: true, watts: 0, adapter: 140,
                     systemPowerIn: 32.0, systemLoad: 32.0),
    lastSeen: now
)

let macHistory = DeviceHistory(
    device: "sample-mac",
    kind: .mac,
    name: "MacBook Pro",
    lastSeen: now,
    health: BatteryHealth(rawMaxMAh: 8389, designMAh: 8579),
    cycleCount: 33,
    temperatureC: 30.3,
    percent: 90,
    isCharging: false,
    lastSession: ChargeSession(
        device: "sample-mac",
        start: macSessionStart,
        end: macSessionEnd,
        fromPercent: 24, toPercent: 100,
        peakWatts: 96.4, averageWatts: 15.1, adapterWatts: 96,
        reached80At: macReached80,
        energyWh: 62.4
    ),
    today: DailyStat(
        device: "sample-mac", day: calendar.startOfDay(for: now),
        minPercent: 41, maxPercent: 100, percentConsumed: 76, percentGained: 90,
        cyclesEstimate: 0.90, minutesOnCharger: 447, averageDrawWatts: 11.3,
        screenOnMinutes: nil, sampleCount: 145
    ),
    week: [],
    series: series([
        (24, 46, false),
        (hoursAgo(macSessionStart), 24, true),
        (hoursAgo(macSessionEnd), 100, false),
        (hoursAgo(midnight.addingTimeInterval(8 * 3600)), 100, false),
        (0, 90, false)
    ]),
    // Twelve consecutive system-load readings behind the "System" row's
    // sparkline — the mock's own numbers (docs/design/summary/gen.py).
    systemLoadSeries: [28, 31, 35, 30, 29, 33, 32, 30, 32, 34, 31, 32]
)

/// A phone on the charger since 13:13, currently at 64 % and still climbing —
/// the open-session case ("→ now", no 80 % line yet).
let phoneStatus = DeviceStatus(
    reading: reading(kind: .iphone, name: "iPhone", percent: 64, charging: true,
                     external: true, watts: 36, adapter: 45,
                     systemPowerIn: 36, systemLoad: 2.4),
    etaTo80: 14 * 60,
    chargingWatts: 36,
    lastSeen: now
)

let phoneHistory = DeviceHistory(
    device: "sample-iphone",
    kind: .iphone,
    name: "iPhone",
    lastSeen: now,
    health: BatteryHealth(rawMaxMAh: 4966, designMAh: 4768),
    cycleCount: 14,
    temperatureC: 28.9,
    percent: 64,
    isCharging: true,
    lastSession: ChargeSession(
        device: "sample-iphone",
        start: phoneSessionStart,
        end: nil,
        fromPercent: 28, toPercent: 64,
        peakWatts: 15.6, averageWatts: 12.58, adapterWatts: 45,
        reached80At: nil,
        energyWh: 21.4
    ),
    today: DailyStat(
        device: "sample-iphone", day: calendar.startOfDay(for: now),
        minPercent: 28, maxPercent: 88, percentConsumed: 60, percentGained: 36,
        cyclesEstimate: 0.36, minutesOnCharger: 132, averageDrawWatts: 1.4,
        screenOnMinutes: nil, sampleCount: 118
    ),
    week: [],
    series: series([
        (24, 88, false), (14, 41, false), (hoursAgo(phoneSessionStart), 28, true), (0, 64, true)
    ]),
    systemLoadSeries: [1.9, 2.4, 2.2, 2.8, 3.1, 2.6, 2.3, 2.0, 2.4, 2.7, 2.5, 2.4]
)

/// Twenty-one days of full readings behind the Mac, and none behind the phone —
/// so the Mac gets a capacity tile and the phone's grid is three tiles, which is
/// the rule the brief asked for: no placeholder where there is no number.
let macTrend = CapacityTrend(
    firstMAh: 8379, lastMAh: 8355,
    first: now.addingTimeInterval(-21 * 86_400), last: now
)

let full: [SummaryDevice] = [
    SummaryDevice(kind: .mac, status: macStatus, history: macHistory, trend: macTrend),
    SummaryDevice(kind: .iphone, status: phoneStatus, history: phoneHistory, trend: nil)
]

/// A store that has never recorded anything: live headers, and every derived
/// block either absent or replaced by one honest sentence.
let empty: [SummaryDevice] = [
    SummaryDevice(kind: .mac, status: macStatus, history: nil, trend: nil),
    SummaryDevice(kind: .iphone, status: phoneStatus, history: nil, trend: nil)
]

// MARK: - Render

@MainActor
func render(_ devices: [SummaryDevice], layout: SummaryLayout, to path: String) {
    let size = layout.size
    let content = Group {
        switch layout {
        case .columns:
            SummaryColumnsBody(devices: devices, now: now)
        case .tabs:
            // Both tabs exist; the render pins the Mac one, which is the tab a
            // plain `tandem://summary` lands on by default.
            SummaryTabsBody(devices: devices, now: now, selection: .mac)
        }
    }
    .frame(width: size.width, height: size.height)
    .background(SummaryPalette.background)
    .environment(\.colorScheme, .dark)

    let renderer = ImageRenderer(content: content)
    renderer.scale = 2
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
struct RenderSummary {

    @MainActor
    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else {
            FileHandle.standardError.write(
                Data("usage: render-summary <out.png> columns|tabs|columns-empty|tabs-empty\n".utf8)
            )
            exit(2)
        }
        let variant = arguments[2]
        let layout: SummaryLayout = variant.hasPrefix("tabs") ? .tabs : .columns
        render(variant.hasSuffix("empty") ? empty : full, layout: layout, to: arguments[1])
    }
}
