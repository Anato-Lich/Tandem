import Foundation
import Testing
@testable import BatteryCore

@Suite("AirPods: system_profiler and the proximity packet")
struct AirPodsTests {

    /// Captured 2026-11-12, lid closed: case 75 %, both buds 100 % and charging.
    static let closedLid = Data([0x4c, 0x00, 0x07, 0x11, 0x06, 0x29, 0x20, 0x0d, 0x4b, 0xe4, 0xe4, 0x5b,
                                 0x02, 0x00, 0x00, 0x00, 0x00, 0x43, 0x84, 0x01, 0x00])

    static func profilerData() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "airpods-profiler", withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    @Test("system_profiler: the AirPods entry, not the mouse, with all three levels")
    func profile() throws {
        let profile = try #require(AirPodsProfile.parse(try Self.profilerData()))
        #expect(profile == AirPodsProfile(name: "AirPods Pro", connected: false, left: 100, right: 100, caseLevel: 75))
    }

    @Test("system_profiler without AirPods gives nothing")
    func noAirPods() {
        let json = #"{"SPBluetoothDataType":[{"device_connected":[{"Mouse":{"device_batteryLevelMain":"40 %"}}]}]}"#
        #expect(AirPodsProfile.parse(Data(json.utf8)) == nil)
    }

    @Test("Closed-lid packet: case and buds, 0x80 is charging")
    func packet() throws {
        let packet = try #require(ProximityStatus.parse(Self.closedLid))
        #expect(packet.caseLevel == .init(percent: 75, charging: false))
        #expect(packet.buds == [.init(percent: 100, charging: true), .init(percent: 100, charging: true)])
    }

    @Test("Other Apple adverts and unknown levels are not misread")
    func packetEdges() {
        var nearby = [UInt8](Self.closedLid); nearby[2] = 0x10
        #expect(ProximityStatus.parse(Data(nearby)) == nil)
        var longForm = [UInt8](Self.closedLid); longForm[3] = 0x19
        #expect(ProximityStatus.parse(Data(longForm)) == nil)
        var unknownCase = [UInt8](Self.closedLid); unknownCase[8] = 0xff
        #expect(ProximityStatus.parse(Data(unknownCase))?.caseLevel == nil)
    }

    @Test("A packet only counts when its numbers are the user's AirPods")
    func matching() throws {
        let packet = try #require(ProximityStatus.parse(Self.closedLid))
        let mine = AirPodsProfile(name: "AirPods Pro", connected: false, left: 100, right: 100, caseLevel: 75)
        #expect(packet.matches(mine))
        var stranger = mine; stranger.caseLevel = 40
        #expect(!packet.matches(stranger))
        stranger = mine; stranger.left = 60
        #expect(!packet.matches(stranger))
    }

    @Test("Ring level is the emptier bud; live for five minutes after last heard")
    func status() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var pods = AirPodsStatus(name: "AirPods", left: 15, right: 22, caseLevel: nil, lastHeard: nil)
        #expect(pods.budsLevel == 15)
        #expect(!pods.isLive(now: now))
        pods.lastHeard = now.addingTimeInterval(-60)
        #expect(pods.isLive(now: now))
        pods.lastHeard = now.addingTimeInterval(-600)
        #expect(!pods.isLive(now: now))
    }

    @Test("A snapshot written before AirPods existed still decodes")
    func oldSnapshot() throws {
        let data = try JSONEncoder().encode(TandemSnapshot(generatedAt: Date(timeIntervalSince1970: 0)))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "airpods")
        let restored = try JSONDecoder().decode(TandemSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(restored.airpods == nil)
    }
}
