import Foundation
import BatteryCore

// MARK: - Argument parsing

struct Options {
    enum Command: String { case once, watch, dump, probe, addresses, lockdown, history, help }
    var command: Command = .once
    var json = false
    var forceNetwork = false
    var keepAlive = false
    var interval: TimeInterval?
    var udid: String?
    var entry = PhoneBatterySource.ioRegistryEntryName
    var out: String?
    /// `watch --stats`: print `TandemMonitor.stats` once a minute.
    var stats = false
    var count = 10
    /// `--direct-only`: never touch usbmuxd for the read.
    var directOnly = false
    /// `--no-direct`: the pre-§12 behaviour, usbmuxd only.
    var noDirect = false
    /// `probe --compare`: run both paths back to back each iteration.
    var compare = false
    /// `probe --tiers`: exercise the shipped two-tier read and say which tier
    /// answered each time.
    var tiers = false
    /// Override the phone's IP instead of using the address book.
    var host: String?
    /// `lockdown` GetValue domain. Empty string means the root domain.
    var domain: String? = "com.apple.mobile.battery"
    /// `lockdown` GetValue key.
    var key: String?
    /// `watch --record`: also append every snapshot to the local history store.
    var record = false
    /// `history --device mac|iphone` (or a literal device id).
    var device: String?
}

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var rest = arguments
    if let first = rest.first, !first.hasPrefix("-") {
        options.command = Options.Command(rawValue: first) ?? .help
        rest.removeFirst()
    }
    var index = 0
    while index < rest.count {
        switch rest[index] {
        case "--json": options.json = true
        case "--network", "-n": options.forceNetwork = true
        case "--keep-alive": options.keepAlive = true
        case "--stats": options.stats = true
        case "--direct-only": options.directOnly = true
        case "--no-direct": options.noDirect = true
        case "--compare": options.compare = true
        case "--record": options.record = true
        case "--device":
            index += 1
            options.device = index < rest.count ? rest[index] : nil
        case "--tiers": options.tiers = true
        case "--host":
            index += 1
            options.host = index < rest.count ? rest[index] : nil
        case "--domain":
            index += 1
            let value = index < rest.count ? rest[index] : ""
            options.domain = value.isEmpty ? nil : value
        case "--key":
            index += 1
            options.key = index < rest.count ? rest[index] : nil
        case "--interval":
            index += 1
            options.interval = index < rest.count ? Double(rest[index]) : nil
        case "--count":
            index += 1
            options.count = index < rest.count ? Int(rest[index]) ?? 1 : 1
        case "--udid", "-u":
            index += 1
            options.udid = index < rest.count ? rest[index] : nil
        case "--entry":
            index += 1
            if index < rest.count { options.entry = rest[index] }
        case "--out", "-o":
            index += 1
            options.out = index < rest.count ? rest[index] : nil
        case "--help", "-h": options.command = .help
        default:
            FileHandle.standardError.write(Data("warning: ignoring unknown argument \(rest[index])\n".utf8))
        }
        index += 1
    }
    return options
}

func printUsage() {
    print("""
    tandemctl - MacBook and iPhone battery, side by side

    USAGE
      tandemctl once  [--json] [--network] [--udid UDID] [--keep-alive]
                      [--direct-only | --no-direct]
      tandemctl watch [--interval SECONDS] [--json] [--network] [--out PATH] [--keep-alive]
                      [--stats]
                      [--record]
      tandemctl history [--device mac|iphone] [--json]
      tandemctl dump  [--network] [--udid UDID] [--entry NAME]   # raw plist to stdout
      tandemctl probe [--interval SECONDS] [--count N] [--keep-alive] [--network]
      tandemctl probe --compare [--interval SECONDS] [--count N] [--host IP]
      tandemctl probe --tiers   [--interval SECONDS] [--count N]
      tandemctl addresses                            # what the address book knows
      tandemctl lockdown [--domain D] [--key K] [--host IP]   # direct GetValue

    OPTIONS
      --json          machine-readable TandemSnapshot JSON
      --network, -n   force the phone to be looked up over Wi-Fi
      --udid, -u      target a specific device
      --interval N    override the polling interval (seconds) for watch
      --out, -o       write each snapshot to PATH as JSON (atomic)
      --keep-alive    reuse the diagnostics_relay connection between reads
      --stats         with watch: print the phone-request counters (attempted /
                      succeeded, broken down by activity level) to stderr every
                      minute -- the measurement behind NOTES.md section 14
      --entry NAME    IORegistry entry for dump (default AppleSmartBattery)
      --count N       number of probe attempts (default 10)
      --direct-only   talk lockdown straight to the phone's IP; never use usbmuxd
      --no-direct     usbmuxd only, the behaviour from before NOTES.md §12
      --compare       probe both paths back to back and summarise (see below)
      --tiers         probe the shipped two-tier read and report, per iteration,
                      full ok / partial ok / failed and the latency
      --host IP       dial this address instead of the remembered one
      --domain D      lockdown GetValue domain (default com.apple.mobile.battery,
                      empty string for the root domain)
      --key K         lockdown GetValue key (default: the whole domain)
      --record        watch: append every snapshot to the local history store
                      (~/Library/Application Support/Tandem/history.sqlite)
      --device D      history: mac, iphone, or a literal device id

    `probe` repeatedly reads the phone and prints one timed line per attempt.
    With --keep-alive it reuses one diagnostics_relay session, which is how the
    session's lifetime over Wi-Fi was measured (see NOTES.md).

    `probe --compare` runs the direct-by-IP client and the usbmuxd path back to
    back on every iteration and prints an ok-count and median/max latency for
    each. It is the measurement behind NOTES.md section 12: during a Bonjour
    blackout the direct path keeps answering while usbmuxd reports "No device
    found".

    `history` prints what the local store has accumulated: battery health and
    cycle count, the last charge session, today's statistics and an ASCII
    sparkline of the last 24 hours. It reads only the SQLite file — no device is
    touched — so it works with the phone off the air. See NOTES.md section 15.

    `probe --tiers` runs the real `PhoneBatterySource.read` — the direct/usbmuxd
    race, then the lockdown GetValue fallback — and reports which tier answered
    each time. It is the measurement behind NOTES.md section 13.
    """)
}

// MARK: - Output helpers

func emit(_ snapshot: TandemSnapshot, json: Bool, store: SnapshotStore) async {
    if json {
        if let data = try? await store.encode(snapshot), let text = String(data: data, encoding: .utf8) {
            print(text)
        }
        return
    }
    var printedAnything = false
    for status in [snapshot.mac, snapshot.phone].compactMap({ $0 }) {
        print(StatusFormatter.line(for: status, now: snapshot.generatedAt))
        printedAnything = true
    }
    if let pods = snapshot.airpods {
        func part(_ label: String, _ level: Int?, _ charging: Bool) -> String {
            "\(label) \(level.map { "\($0) %" } ?? "—")\(charging ? "+" : "")"
        }
        let heard = pods.lastHeard.map { "heard \(Int(snapshot.generatedAt.timeIntervalSince($0))) s ago" } ?? "not heard"
        print("\(pods.name)  \(part("L", pods.left, pods.leftCharging))  \(part("R", pods.right, pods.rightCharging))  \(part("case", pods.caseLevel, pods.caseCharging))  \(heard)")
        printedAnything = true
    }
    if !printedAnything { print("no devices") }
}

func makeMonitor(_ options: Options, store: SnapshotStore?) -> TandemMonitor {
    var policy = PollingPolicy()
    if let interval = options.interval {
        // Every phone cadence, not just the widget-visible pair: a CLI has no
        // popover and no widget, so it runs at `.background` (NOTES.md §14)
        // and would otherwise ignore `--interval` entirely.
        policy.chargingInterval = interval
        policy.dischargingInterval = interval
        policy.backgroundChargingInterval = interval
        policy.backgroundDischargingInterval = interval
    }
    let configuration = TandemMonitor.Configuration(
        keepPhoneSessionAlive: options.keepAlive,
        preferNetworkTransport: options.forceNetwork,
        useDirectClient: !options.noDirect,
        directOnly: options.directOnly,
        policy: policy
    )
    return TandemMonitor(store: store, configuration: configuration)
}

/// Pick a phone. With the direct path in play we also accept a phone that only
/// the address book knows about, because usbmuxd goes blind during a blackout —
/// which is exactly when we want to be reading.
func resolveDevice(
    _ source: PhoneBatterySource,
    options: Options,
    allowRemembered: Bool = false
) async throws -> PhoneDevice {
    let devices = allowRemembered
        ? await source.addressableDevices()
        : await source.discoverWithRetry()
    guard !devices.isEmpty else { throw PhoneError.noDevice(udid: options.udid) }
    var chosen: PhoneDevice
    if let udid = options.udid {
        guard let match = devices.first(where: { $0.udid == udid }) else {
            throw PhoneError.noDevice(udid: udid)
        }
        chosen = match
    } else {
        chosen = devices[0]
    }
    if options.forceNetwork { chosen.transport = .wifi }
    return chosen
}

func stamp() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

// MARK: - probe --compare

/// Latency bookkeeping for one leg of `probe --compare`.
struct LegStats {
    var name: String
    var okCount = 0
    var attempts = 0
    var latencies: [TimeInterval] = []
    var firstError: String?

    mutating func record(ok: Bool, seconds: TimeInterval, error: String?) {
        attempts += 1
        if ok {
            okCount += 1
            latencies.append(seconds)
        } else if firstError == nil {
            firstError = error
        }
    }

    var median: TimeInterval? {
        guard !latencies.isEmpty else { return nil }
        let sorted = latencies.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 1
            ? sorted[middle]
            : (sorted[middle - 1] + sorted[middle]) / 2
    }

    var maximum: TimeInterval? { latencies.max() }

    var summary: String {
        let median = self.median.map { String(format: "%.2f s", $0) } ?? "--"
        let maximum = self.maximum.map { String(format: "%.2f s", $0) } ?? "--"
        return String(
            format: "  %-7@ ok %2d/%-2d  median %@  max %@",
            name as NSString, okCount, attempts, median as NSString, maximum as NSString
        )
    }
}

/// One iteration of `--compare`: direct-by-IP, then usbmuxd, back to back.
func runCompare(_ options: Options) async {
    // attempts: 1 so a failure is reported rather than papered over by a retry;
    // the whole point is to count failures per path.
    let source = PhoneBatterySource(
        retryPolicy: PhoneRetryPolicy(attempts: 1, gap: 0, deadline: 12)
    )
    let interval = options.interval ?? 15

    // Seed the address book while the phone is (hopefully) still visible.
    await source.refreshAddresses()
    var device: PhoneDevice
    do {
        device = try await resolveDevice(source, options: options, allowRemembered: true)
    } catch {
        FileHandle.standardError.write(
            Data("error: \(error)\nNo phone is visible and none is remembered; run `tandemctl once` while the phone is reachable first.\n".utf8)
        )
        exit(1)
    }
    device.transport = .wifi

    var hosts = options.host.map { [$0] } ?? []
    if hosts.isEmpty { hosts = await source.knownHosts(for: device.udid) }
    guard let seeded = hosts.first else {
        FileHandle.standardError.write(
            Data("error: no network address known for \(device.udid); pass --host or run once while the phone is on Wi-Fi\n".utf8)
        )
        exit(1)
    }
    let extra = hosts.dropFirst().isEmpty ? "" : " (fallbacks: \(hosts.dropFirst().joined(separator: ", ")))"
    print("comparing direct \(seeded):62078\(extra) against the usbmuxd path for \(device.name) (\(device.udid))")

    var direct = LegStats(name: "direct")
    var usbmux = LegStats(name: "usbmux")
    var directOnlyWins = 0
    var usbmuxOnlyWins = 0
    var bothFailed = 0

    for attempt in 1...options.count {
        var line = String(format: "%@ #%02d", stamp(), attempt)

        let directStarted = Date()
        var directOK = false
        do {
            let reading = try await source.readDirect(device, hosts: hosts)
            directOK = true
            let elapsed = Date().timeIntervalSince(directStarted)
            direct.record(ok: true, seconds: elapsed, error: nil)
            line += String(
                format: "  direct ok %.3f s %d %% %+d mA",
                elapsed, reading.percent, reading.instantAmperageMA
            )
        } catch {
            let elapsed = Date().timeIntervalSince(directStarted)
            direct.record(ok: false, seconds: elapsed, error: String(describing: error))
            line += String(format: "  direct FAIL %.3f s [%@]", elapsed, String(describing: error) as NSString)
        }

        let muxStarted = Date()
        var muxOK = false
        do {
            let reading = try await source.readViaUSBMux(device)
            muxOK = true
            let elapsed = Date().timeIntervalSince(muxStarted)
            usbmux.record(ok: true, seconds: elapsed, error: nil)
            line += String(
                format: "  |  usbmux ok %.3f s %d %%",
                elapsed, reading.percent
            )
            // usbmuxd can see the phone, so this is the moment to refresh the IP.
            if options.host == nil,
               let refreshed = await source.refreshAddresses().first(where: { $0.udid == device.udid })?.candidates,
               refreshed != hosts {
                line += "  (addresses now \(refreshed.joined(separator: ", ")))"
                hosts = refreshed
            }
        } catch {
            let elapsed = Date().timeIntervalSince(muxStarted)
            usbmux.record(ok: false, seconds: elapsed, error: String(describing: error))
            line += String(format: "  |  usbmux FAIL %.3f s [%@]", elapsed, String(describing: error) as NSString)
        }

        if directOK && !muxOK { directOnlyWins += 1 }
        if muxOK && !directOK { usbmuxOnlyWins += 1 }
        if !directOK && !muxOK { bothFailed += 1 }

        print(line)
        fflush(stdout)
        if attempt < options.count { try? await Task.sleep(for: .seconds(interval)) }
    }

    print("")
    print("summary over \(options.count) iterations at \(Int(interval)) s")
    print(direct.summary)
    print(usbmux.summary)
    print("  direct only: \(directOnlyWins)   usbmux only: \(usbmuxOnlyWins)   both failed: \(bothFailed)")
    if let error = direct.firstError { print("  first direct failure: \(error)") }
    if let error = usbmux.firstError { print("  first usbmux failure: \(error)") }
}

/// One iteration of `--tiers`: the shipped two-tier read, reported by tier.
func runTiers(_ options: Options) async {
    // attempts: 1 so a failure is a failure; the race and the degraded tier are
    // what we are measuring, not the retry ladder on top of them.
    let source = PhoneBatterySource(retryPolicy: PhoneRetryPolicy(attempts: 1, gap: 0, deadline: 5))
    let interval = options.interval ?? 15

    await source.refreshAddresses()
    var device: PhoneDevice
    do {
        device = try await resolveDevice(source, options: options, allowRemembered: true)
    } catch {
        FileHandle.standardError.write(
            Data("error: \(error)\nNo phone is visible and none is remembered; run `tandemctl once` while the phone is reachable first.\n".utf8)
        )
        exit(1)
    }
    if options.forceNetwork { device.transport = .wifi }

    let hosts = await source.knownHosts(for: device.udid)
    print("tiered read of \(device.name) (\(device.udid)) over \(device.transport.rawValue), addresses \(hosts.isEmpty ? "none" : hosts.joined(separator: ", "))")

    var full = LegStats(name: "full")
    var partial = LegStats(name: "partial")
    var failed = 0
    var latencies: [TimeInterval] = []

    for attempt in 1...options.count {
        let started = Date()
        var line: String
        do {
            let reading = try await source.read(device)
            let elapsed = Date().timeIntervalSince(started)
            latencies.append(elapsed)
            let route = await source.lastRoute
            let label = route.map(\.rawValue) ?? "?"
            if reading.isPartial {
                partial.record(ok: true, seconds: elapsed, error: nil)
                full.record(ok: false, seconds: elapsed, error: await source.lastRouteErrors[.direct] ?? "full tier failed")
                line = String(
                    format: "%@ #%02d partial ok %.3f s  %d %%  %@  via %@",
                    stamp(), attempt, elapsed, reading.percent,
                    reading.isCharging ? "charging" : "discharging", label as NSString
                )
            } else {
                full.record(ok: true, seconds: elapsed, error: nil)
                // The partial tier was never asked, so it is not counted here.
                line = String(
                    format: "%@ #%02d full ok    %.3f s  %d %%  %+d mA  via %@",
                    stamp(), attempt, elapsed, reading.percent,
                    reading.instantAmperageMA, label as NSString
                )
            }
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            failed += 1
            full.record(ok: false, seconds: elapsed, error: String(describing: error))
            let typed = MonitorError(error)
            line = String(
                format: "%@ #%02d failed     %.3f s  %@ [%@]",
                stamp(), attempt, elapsed, typed.localizedKey as NSString,
                String(describing: error) as NSString
            )
        }
        print(line)
        fflush(stdout)
        if attempt < options.count { try? await Task.sleep(for: .seconds(interval)) }
    }

    let sorted = latencies.sorted()
    let median = sorted.isEmpty
        ? "--"
        : String(format: "%.2f s", sorted[sorted.count / 2])
    let worst = sorted.last.map { String(format: "%.2f s", $0) } ?? "--"
    print("")
    print("summary over \(options.count) iterations at \(Int(interval)) s")
    print("  full ok    \(full.okCount)/\(options.count)")
    print("  partial ok \(partial.okCount)/\(options.count)")
    print("  failed     \(failed)/\(options.count)")
    print("  latency    median \(median)  max \(worst)")
    if let error = full.firstError { print("  first full-tier failure: \(error)") }
}

// MARK: - history

/// Eight block glyphs over the full 0-100 % range, so the shape is honest: a
/// battery that never left 70-80 % renders as a flat line rather than as a
/// dramatic swing.
func sparkline(_ series: [SeriesPoint]) -> String {
    guard !series.isEmpty else { return "(no data)" }
    let blocks = Array("\u{2581}\u{2582}\u{2583}\u{2584}\u{2585}\u{2586}\u{2587}\u{2588}")
    return String(series.map { point -> Character in
        let clamped = max(0, min(100, point.percent))
        return blocks[min(blocks.count - 1, clamped * blocks.count / 101)]
    })
}

/// `+` under every point that was charging, spaces elsewhere. Printed beneath
/// the sparkline so the chart says *when* the charger was on.
func chargeLine(_ series: [SeriesPoint]) -> String {
    String(series.map { $0.isCharging ? Character("+") : Character(" ") })
}

func clockTime(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

func dayAndClock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "dd MMM HH:mm"
    return formatter.string(from: date)
}

func renderHistory(_ entry: DeviceHistory) {
    let title = entry.name.flatMap { $0.isEmpty ? nil : $0 } ?? entry.device
    print("\(title) - \(entry.kind?.rawValue ?? "unknown")")

    var healthParts: [String] = []
    if let health = entry.health {
        healthParts.append("\(health.percent) % (\(health.rawMaxMAh) / \(health.designMAh) mAh)")
    } else {
        healthParts.append("unknown")
    }
    healthParts.append("cycles \(entry.cycleCount.map(String.init) ?? "unknown")")
    if let temperature = entry.temperatureC {
        healthParts.append(String(format: "%.1f \u{00B0}C", temperature))
    }
    if let percent = entry.percent {
        healthParts.append("now \(percent) %\((entry.isCharging ?? false) ? ", charging" : "")")
    }
    print("  health   " + healthParts.joined(separator: "   "))

    if let session = entry.lastSession {
        var parts = ["\(dayAndClock(session.start)) \u{2192} \(session.end.map(clockTime) ?? "now")"]
        parts.append("\(session.fromPercent) % \u{2192} \(session.toPercent) %")
        if let average = session.averageWatts { parts.append(String(format: "avg %.1f W", average)) }
        if let peak = session.peakWatts { parts.append(String(format: "peak %.1f W", peak)) }
        if let adapter = session.adapterWatts { parts.append("\(adapter) W adapter") }
        if let reached = session.reached80At { parts.append("80 % at \(clockTime(reached))") }
        if let energy = session.energyWh { parts.append(String(format: "%.1f Wh", energy)) }
        print("  session  " + parts.joined(separator: "  "))
    } else {
        print("  session  none recorded")
    }

    if let today = entry.today {
        var parts = ["\(today.minPercent) %\u{2013}\(today.maxPercent) %"]
        parts.append("used \(today.percentConsumed) %")
        parts.append("gained \(today.percentGained) %")
        parts.append(String(format: "cycles %.2f", today.cyclesEstimate))
        // English like the rest of the CLI, whatever the machine's language is.
        parts.append("charger \(StatusFormatter.shortDuration(today.minutesOnCharger * 60, units: .english))")
        if let draw = today.averageDrawWatts { parts.append(String(format: "avg draw %.1f W", draw)) }
        parts.append("screen-on unknown")
        print("  today    " + parts.joined(separator: "  "))
    } else {
        print("  today    no readings yet")
    }

    print("  24 h     " + sparkline(entry.series) + "   (\(entry.series.count) pts)")
    let charge = chargeLine(entry.series)
    if charge.contains("+") { print("           " + charge) }
}

func runHistory(_ options: Options) async {
    let store = HistoryStore()
    do {
        var summary = try await store.summary()
        if let token = options.device {
            guard let resolved = try await store.resolveDevice(token) else {
                FileHandle.standardError.write(Data("history: no device matching \(token)\n".utf8))
                exit(1)
            }
            summary.devices = summary.devices.filter { $0.device == resolved.id }
        }
        if options.json {
            let data = try await store.encodeSummary(summary)
            print(String(data: data, encoding: .utf8) ?? "{}")
            return
        }
        guard !summary.devices.isEmpty else {
            print("no history yet - run `tandemctl watch --record`")
            print("file: \(store.url.path)")
            return
        }
        for (index, entry) in summary.devices.enumerated() {
            if index > 0 { print("") }
            renderHistory(entry)
        }
        print("")
        print("file: \(store.url.path)")
    } catch {
        FileHandle.standardError.write(Data("history: \(error)\n".utf8))
        exit(1)
    }
}

// MARK: - Commands

@main
struct Tandemctl {
    static func main() async {
        let options = parse(Array(CommandLine.arguments.dropFirst()))
        let encodingStore = SnapshotStore(url: URL(fileURLWithPath: "/dev/null"))

        switch options.command {
        case .help:
            printUsage()

        case .once:
            let store = options.out.map { SnapshotStore(url: URL(fileURLWithPath: $0)) }
            let monitor = makeMonitor(options, store: store)
            let started = Date()
            let snapshot = await monitor.pollOnce()
            await emit(snapshot, json: options.json, store: encodingStore)
            if !options.json {
                if let error = await monitor.lastMacError {
                    FileHandle.standardError.write(Data("mac: \(error)\n".utf8))
                }
                if let error = await monitor.lastPhoneError {
                    FileHandle.standardError.write(Data("phone: \(error)\n".utf8))
                }
                let elapsed = Date().timeIntervalSince(started)
                FileHandle.standardError.write(Data(String(format: "took %.3f s\n", elapsed).utf8))
            }
            if snapshot.mac == nil && snapshot.phone == nil { exit(1) }

        case .watch:
            let store = options.out.map { SnapshotStore(url: URL(fileURLWithPath: $0)) }
            let monitor = makeMonitor(options, store: store)
            var lastMac: String?
            var lastPhone: String?
            // The energy policy's own instrumentation (NOTES.md section 14):
            // one line now and one a minute after that, so a short run shows
            // both the cadence in force and what it has actually cost.
            let statsTask: Task<Void, Never>? = options.stats ? Task {
                while !Task.isCancelled {
                    let stats = await monitor.stats
                    FileHandle.standardError.write(Data("\(stamp()) stats  \(stats.summary())\n".utf8))
                    try? await Task.sleep(for: .seconds(60))
                }
            } : nil
            defer { statsTask?.cancel() }
            // Recorded inline rather than through `HistoryRecorder.attach`,
            // because `snapshots()` starts its own polling loops and this loop
            // already owns one (NOTES.md section 15).
            let history = options.record ? HistoryStore() : nil
            for await snapshot in await monitor.snapshots() {
                if let history { await HistoryRecorder.record(snapshot, into: history) }
                await emit(snapshot, json: options.json, store: encodingStore)
                let macError = await monitor.lastMacError
                let phoneError = await monitor.lastPhoneError
                if macError != lastMac, let macError {
                    FileHandle.standardError.write(Data("\(stamp()) mac: \(macError)\n".utf8))
                }
                if phoneError != lastPhone, let phoneError {
                    FileHandle.standardError.write(Data("\(stamp()) phone: \(phoneError)\n".utf8))
                }
                lastMac = macError
                lastPhone = phoneError
                if !options.json { print("--") }
                fflush(stdout)
            }

        case .lockdown:
            // Direct lockdown GetValue, no service. Diagnostic: it stops one
            // protocol step before the IORegistry read, so if this answers and
            // `once --direct-only` does not, diagnostics_relay is the thing
            // refusing rather than the phone being unreachable.
            let source = PhoneBatterySource()
            do {
                let device = try await resolveDevice(source, options: options, allowRemembered: true)
                var hosts = options.host.map { [$0] } ?? []
                if hosts.isEmpty { hosts = await source.knownHosts(for: device.udid) }
                let started = Date()
                let data = try await source.directClient.lockdownValue(
                    udid: device.udid,
                    hosts: hosts,
                    domain: options.domain,
                    key: options.key
                )
                FileHandle.standardError.write(
                    Data(String(format: "took %.3f s\n", Date().timeIntervalSince(started)).utf8)
                )
                FileHandle.standardOutput.write(data)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }

        case .history:
            await runHistory(options)

        case .addresses:
            let source = PhoneBatterySource()
            let live = await source.refreshAddresses()
            for stored in await source.addressBook.all() {
                let entry = await source.addressBook.dialableAddress(for: stored.udid) ?? stored
                let alternates = entry.alternateHosts?.joined(separator: ", ") ?? "-"
                let fresh = live.contains(where: { $0.udid == entry.udid }) ? "visible now" : "remembered"
                print("\(entry.udid)  \(entry.name ?? "iPhone")")
                print("  host \(entry.host)   alternates \(alternates)")
                print("  last seen \(entry.lastSeen)  (\(fresh))")
                if entry.host.contains(":") {
                    print("  neighbour-table IPv4: \(NeighborTable.ipv4Peer(of: entry.host) ?? "unknown")")
                }
            }
            print("file: \(source.addressBook.url.path)")

        case .probe where options.tiers:
            await runTiers(options)

        case .probe where options.compare:
            await runCompare(options)

        case .probe:
            let source = PhoneBatterySource(retryPolicy: PhoneRetryPolicy(attempts: 1, gap: 0, deadline: 10))
            if options.keepAlive { await source.setKeepAlive(true) }
            let interval = options.interval ?? 15
            var device: PhoneDevice?
            for attempt in 1...options.count {
                let started = Date()
                var line = ""
                do {
                    let target: PhoneDevice
                    if let device {
                        target = device
                    } else {
                        target = try await resolveDevice(source, options: options)
                        device = target
                    }
                    let reading = try await source.read(target)
                    let age = await source.sessionAge(target.udid)
                    line = String(
                        format: "%@ #%02d ok %.3f s  %d %%  %+d mA  session %@",
                        stamp(), attempt, Date().timeIntervalSince(started),
                        reading.percent, reading.instantAmperageMA,
                        age.map { String(format: "%.0f s old", $0) } ?? "fresh"
                    )
                } catch {
                    line = String(
                        format: "%@ #%02d FAIL %.3f s  %@",
                        stamp(), attempt, Date().timeIntervalSince(started), String(describing: error)
                    )
                    device = nil
                }
                print(line)
                fflush(stdout)
                if attempt < options.count { try? await Task.sleep(for: .seconds(interval)) }
            }

        case .dump:
            let source = PhoneBatterySource()
            do {
                let device = try await resolveDevice(source, options: options)
                FileHandle.standardError.write(
                    Data("dumping \(options.entry) from \(device.name) (\(device.udid)) over \(device.transport.rawValue)\n".utf8)
                )
                let data = try await source.dump(device, entryName: options.entry)
                FileHandle.standardOutput.write(data)
            } catch {
                FileHandle.standardError.write(Data("error: \(error)\n".utf8))
                exit(1)
            }
        }
    }
}
