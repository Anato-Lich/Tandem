import CoreBluetooth
import Foundation

/// The user's AirPods: both buds and the case, as the Mac last heard them.
public struct AirPodsStatus: Sendable, Codable, Equatable {
    public var name: String
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?
    public var leftCharging = false
    public var rightCharging = false
    public var caseCharging = false
    /// Last proof the numbers are current: a matching BLE packet, a change in
    /// the values, or the AirPods being connected (work/2026-11-12-airpods, D3).
    /// `nil` until the first such proof since launch.
    public var lastHeard: Date?

    public init(name: String, left: Int?, right: Int?, caseLevel: Int?, lastHeard: Date?) {
        self.name = name
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
        self.lastHeard = lastHeard
    }

    /// The bud that runs out first — what the ring's percent and colour follow.
    public var budsLevel: Int? {
        switch (left, right) {
        case let (l?, r?): return min(l, r)
        case let (l?, nil): return l
        case let (nil, r?): return r
        case (nil, nil): return nil
        }
    }

    public var isCharging: Bool { leftCharging || rightCharging || caseCharging }

    /// Not heard for this long and the UI shows the time instead of a bolt.
    public static let liveWindow: TimeInterval = 5 * 60

    public func isLive(now: Date = Date()) -> Bool {
        lastHeard.map { now.timeIntervalSince($0) < Self.liveWindow } ?? false
    }
}

/// One AirPods entry from `system_profiler SPBluetoothDataType -json`.
public struct AirPodsProfile: Sendable, Equatable {
    public var name: String
    public var connected: Bool
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?

    /// The first paired device that reports a left or right bud level.
    public static func parse(_ data: Data) -> AirPodsProfile? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        for section in sections {
            for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
                for entry in section[key] as? [[String: Any]] ?? [] {
                    for (name, value) in entry {
                        guard let props = value as? [String: Any] else { continue }
                        let left = percent(props["device_batteryLevelLeft"])
                        let right = percent(props["device_batteryLevelRight"])
                        guard left != nil || right != nil else { continue }
                        return AirPodsProfile(name: name, connected: connected, left: left, right: right,
                                              caseLevel: percent(props["device_batteryLevelCase"]))
                    }
                }
            }
        }
        return nil
    }

    /// "75 %" → 75.
    static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        return Int(text.filter(\.isNumber)).flatMap { (0...100).contains($0) ? $0 : nil }
    }
}

/// The closed-lid "accessory status" form of Apple's proximity-pairing advert:
/// `4c 00 07 11 06 <model:2> <?> <case> <bud> <bud> …`. Each level byte is a
/// percent, `0x80` set = charging, `0xff` = unknown. Which bud byte is left is
/// not relied on (DECISIONS D4).
public struct ProximityStatus: Sendable, Equatable {
    public struct Level: Sendable, Equatable {
        public var percent: Int
        public var charging: Bool
    }
    public var caseLevel: Level?
    public var buds: [Level]

    public static func parse(_ data: Data) -> ProximityStatus? {
        let d = [UInt8](data)
        guard d.count >= 11, d[0] == 0x4c, d[1] == 0x00, d[2] == 0x07, d[3] == 0x11, d[4] == 0x06 else { return nil }
        func level(_ byte: UInt8) -> Level? {
            let percent = Int(byte & 0x7f)
            return byte == 0xff || percent > 100 ? nil : Level(percent: percent, charging: byte & 0x80 != 0)
        }
        return ProximityStatus(caseLevel: level(d[8]), buds: [d[9], d[10]].compactMap(level))
    }

    /// True when this packet carries the same numbers as the profile.
    func matches(_ profile: AirPodsProfile) -> Bool {
        let profileBuds = [profile.left, profile.right].compactMap { $0 }.sorted()
        guard !profileBuds.isEmpty, buds.map(\.percent).sorted() == profileBuds else { return false }
        if let mine = caseLevel?.percent, let theirs = profile.caseLevel { return mine == theirs }
        return true
    }
}

/// Reads the AirPods: numbers from `system_profiler`, liveness and charging
/// from a short CoreBluetooth scan (DECISIONS D1–D3).
public final class AirPodsSource: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.tandem.airpods")
    private var central: CBCentralManager?
    /// Short-form packets heard during the current scan, newest last.
    private var heard: [(Date, ProximityStatus)] = []
    private var previous: AirPodsStatus?
    /// Only inside a scan window; a radio switched on later must not start an endless scan.
    private var wantsScan = false
    private let scanSeconds: TimeInterval

    /// Closed-lid adverts arrive every 2–20 s (measured), so the window is 20 s;
    /// it ends as soon as a matching packet is heard.
    public init(scanSeconds: TimeInterval = 20) {
        self.scanSeconds = scanSeconds
        super.init()
    }

    /// `nil` when no AirPods are paired with this Mac.
    public func read(now: Date = Date()) async -> AirPodsStatus? {
        guard let data = await Self.runProfiler(), let profile = AirPodsProfile.parse(data) else { return nil }
        let packets = await scan { $0.matches(profile) }
        let match = packets.last { $0.1.matches(profile) }

        var status = AirPodsStatus(name: profile.name, left: profile.left, right: profile.right,
                                   caseLevel: profile.caseLevel, lastHeard: previous?.lastHeard)
        let changed = previous.map { ($0.left, $0.right, $0.caseLevel) != (status.left, status.right, status.caseLevel) } ?? false
        if profile.connected || changed { status.lastHeard = now }
        if let (time, packet) = match {
            status.lastHeard = max(status.lastHeard ?? time, time)
            status.caseCharging = packet.caseLevel?.charging ?? false
            for bud in packet.buds {
                if bud.percent == status.left { status.leftCharging = status.leftCharging || bud.charging }
                if bud.percent == status.right { status.rightCharging = status.rightCharging || bud.charging }
            }
        }
        previous = status
        return status
    }

    // MARK: - system_profiler

    static func runProfiler() async -> Data? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            process.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { continuation.resume(returning: nil); return }
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }

    // MARK: - BLE

    /// Scan for `scanSeconds` and return the short-form packets heard. Empty
    /// when Bluetooth is off or not authorised — liveness then rests on D3.
    private func scan(until done: (ProximityStatus) -> Bool) async -> [(Date, ProximityStatus)] {
        queue.sync {
            heard.removeAll()
            wantsScan = true
            if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
            else if central?.state == .poweredOn { startScan() }
        }
        let deadline = Date().addingTimeInterval(scanSeconds)
        while Date() < deadline, !Task.isCancelled, !queue.sync(execute: { heard.contains { done($0.1) } }) {
            try? await Task.sleep(for: .milliseconds(500))
        }
        return queue.sync {
            wantsScan = false
            central?.stopScan()
            return heard
        }
    }

    private func startScan() {
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, wantsScan { startScan() }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              let packet = ProximityStatus.parse(data) else { return }
        heard.append((Date(), packet))
    }
}
