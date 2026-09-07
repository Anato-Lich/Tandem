import Foundation
import Testing
@testable import BatteryCore

// MARK: - Fakes

/// A pair of fake transports for `PhoneReadRace`.
///
/// Each leg can succeed, fail, or take its time before doing either, and every
/// leg records whether it was started and whether it was cancelled — which is
/// how "the loser really was cancelled" gets asserted without a phone.
actor FakeRaceTransport {

    enum Behaviour: Sendable {
        case succeeds(percent: Int, after: Duration = .zero)
        /// Fails in a way that says the phone answered and the relay did not.
        case relayRefused(after: Duration = .zero)
        /// Fails in a way that says the radio is off.
        case unreachable(after: Duration = .zero)
        case never
    }

    private var behaviours: [PhoneReadRace.Route: Behaviour]
    private(set) var started: [PhoneReadRace.Route] = []
    private(set) var finished: [PhoneReadRace.Route] = []
    private(set) var cancelled: [PhoneReadRace.Route] = []

    init(_ behaviours: [PhoneReadRace.Route: Behaviour]) {
        self.behaviours = behaviours
    }

    private func noteStart(_ route: PhoneReadRace.Route) { started.append(route) }
    private func noteFinish(_ route: PhoneReadRace.Route) { finished.append(route) }
    private func noteCancel(_ route: PhoneReadRace.Route) { cancelled.append(route) }

    func leg(_ route: PhoneReadRace.Route) -> PhoneReadRace.Leg {
        PhoneReadRace.Leg(route) { [self] in
            await noteStart(route)
            let behaviour = await behaviour(for: route)
            let delay: Duration
            switch behaviour {
            case .succeeds(_, let after), .relayRefused(let after), .unreachable(let after):
                delay = after
            case .never:
                delay = .seconds(60)
            }
            if delay != .zero {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    await noteCancel(route)
                    throw CancellationError()
                }
            }
            await noteFinish(route)
            switch behaviour {
            case .succeeds(let percent, _):
                var reading = makeReading(percent: percent, viaDirect: route.usesDirect)
                if route.isPartial {
                    reading = BatteryReading.partial(
                        deviceID: reading.deviceID, name: reading.name, percent: percent,
                        isCharging: true, externalConnected: true,
                        timestamp: referenceDate, viaDirect: route.usesDirect
                    )
                }
                return reading
            case .relayRefused:
                throw DirectLockdownError.ioFailed(
                    step: "IORegistry", detail: "SSL error 1: unexpected eof while reading"
                )
            case .unreachable:
                throw DirectLockdownError.timedOut(step: "connect 192.0.2.10:62078", after: 8)
            case .never:
                throw CancellationError()
            }
        }
    }

    private func behaviour(for route: PhoneReadRace.Route) -> Behaviour {
        behaviours[route] ?? .unreachable()
    }
}

// MARK: - The race

@Suite("Two-transport race and the degraded tier")
struct PhoneReadRaceTests {

    @Test("The first success wins and the slower leg is cancelled")
    func fastestWins() async throws {
        let transport = FakeRaceTransport([
            .direct: .succeeds(percent: 71),
            .usbmux: .succeeds(percent: 42, after: .seconds(30)),
        ])
        let race = PhoneReadRace(budget: 8)
        let outcome = try await race.read(
            full: [await transport.leg(.direct), await transport.leg(.usbmux)]
        )

        #expect(outcome.route == .direct)
        #expect(outcome.reading.percent == 71)
        #expect(!outcome.isPartial)
        // The loser was started, and it never got to finish.
        #expect(await transport.started.contains(.usbmux))
        #expect(!(await transport.finished.contains(.usbmux)))
    }

    @Test("A slow direct leg does not hold up a usbmuxd path that answers")
    func usbmuxCanWin() async throws {
        let transport = FakeRaceTransport([
            .direct: .never,
            .usbmux: .succeeds(percent: 42),
        ])
        let started = Date()
        let outcome = try await PhoneReadRace(budget: 8).read(
            full: [await transport.leg(.direct), await transport.leg(.usbmux)]
        )

        #expect(outcome.route == .usbmux)
        #expect(outcome.reading.percent == 42)
        // The whole point: the 8 s direct connect is paid in parallel, not first.
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("Both full legs failing reachably drops to the partial tier, direct first")
    func fallsBackToPartial() async throws {
        let transport = FakeRaceTransport([
            .direct: .relayRefused(),
            .usbmux: .relayRefused(),
            .directPartial: .succeeds(percent: 66),
            .usbmuxPartial: .succeeds(percent: 65),
        ])
        let outcome = try await PhoneReadRace(budget: 8).read(
            full: [await transport.leg(.direct), await transport.leg(.usbmux)],
            partial: [await transport.leg(.directPartial), await transport.leg(.usbmuxPartial)]
        )

        #expect(outcome.route == .directPartial)
        #expect(outcome.isPartial)
        #expect(outcome.reading.isPartial)
        #expect(outcome.reading.percent == 66)
        // Both full failures are reported alongside the degraded answer.
        #expect(outcome.errors[.direct] != nil)
        #expect(outcome.errors[.usbmux] != nil)
    }

    @Test("An unreachable phone is not dialled a second time for a partial read")
    func skipsPartialWhenRadioIsOff() async throws {
        let transport = FakeRaceTransport([
            .direct: .unreachable(),
            .usbmux: .unreachable(),
            .directPartial: .succeeds(percent: 66),
        ])
        await #expect(throws: DirectLockdownError.self) {
            try await PhoneReadRace(budget: 8).read(
                full: [await transport.leg(.direct), await transport.leg(.usbmux)],
                partial: [await transport.leg(.directPartial)]
            )
        }
        #expect(await transport.started.isEmpty == false)
        #expect(!(await transport.started.contains(.directPartial)))
    }

    @Test("alwaysTryPartial overrides the reachability check")
    func alwaysTryPartial() async throws {
        let transport = FakeRaceTransport([
            .direct: .unreachable(),
            .directPartial: .succeeds(percent: 66),
        ])
        let outcome = try await PhoneReadRace(budget: 8, alwaysTryPartial: true).read(
            full: [await transport.leg(.direct)],
            partial: [await transport.leg(.directPartial)]
        )
        #expect(outcome.route == .directPartial)
    }

    @Test("The first leg's error is the one thrown, so --direct-only still reports it")
    func throwsTheLeadingError() async throws {
        let transport = FakeRaceTransport([.direct: .unreachable()])
        let error = await #expect(throws: DirectLockdownError.self) {
            try await PhoneReadRace(budget: 8).read(full: [await transport.leg(.direct)])
        }
        #expect(error?.step == "connect 192.0.2.10:62078")
    }

    @Test("The budget caps the whole read even when no leg ever answers")
    func budgetIsHonoured() async throws {
        let transport = FakeRaceTransport([.direct: .never, .usbmux: .never])
        let started = Date()
        await #expect(throws: (any Error).self) {
            try await PhoneReadRace(budget: 1).read(
                full: [await transport.leg(.direct), await transport.leg(.usbmux)]
            )
        }
        #expect(Date().timeIntervalSince(started) < 4)
    }

    @Test("Offering no legs at all is a no-device answer, not a hang")
    func noLegs() async {
        await #expect(throws: MonitorError.noDevice) {
            try await PhoneReadRace().read(full: [], partial: [])
        }
    }

    @Test("Only a relay-shaped failure suggests the degraded tier")
    func classification() {
        #expect(PhoneReadRace.suggestsPartialTier(
            DirectLockdownError.ioFailed(step: "IORegistry", detail: "eof")
        ))
        #expect(PhoneReadRace.suggestsPartialTier(PhoneError.serviceFailed(code: -27)))
        #expect(PhoneReadRace.suggestsPartialTier(PhoneError.emptyResponse))
        #expect(!PhoneReadRace.suggestsPartialTier(PhoneError.noDevice(udid: "u")))
        #expect(!PhoneReadRace.suggestsPartialTier(
            DirectLockdownError.timedOut(step: "connect 1.2.3.4:62078", after: 8)
        ))
        #expect(!PhoneReadRace.suggestsPartialTier(
            DirectLockdownError.noPairRecord(udid: "u", code: -1)
        ))
    }
}

// MARK: - Partial readings

@Suite("Partial readings")
struct PartialReadingTests {

    private func batteryDomainPlist(
        percent: Int = 66,
        charging: Bool = true,
        external: Bool = true,
        fullyCharged: Bool = false
    ) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "BatteryCurrentCapacity": percent,
                "BatteryIsCharging": charging,
                "ExternalConnected": external,
                "FullyCharged": fullyCharged,
            ] as [String: Any],
            format: .xml,
            options: 0
        )
    }

    @Test("The battery domain decodes into a partial reading with nothing invented")
    func parsesDomain() throws {
        let reading = try BatteryPlistParser.parseBatteryDomain(
            try batteryDomainPlist(), deviceID: "udid", name: "iPhone",
            viaDirect: true, timestamp: referenceDate
        )
        #expect(reading.isPartial)
        #expect(reading.percent == 66)
        #expect(reading.isCharging)
        #expect(reading.externalConnected)
        #expect(reading.viaDirect)
        // Unknown, not zero — and never rendered.
        #expect(reading.rawMaxMAh == 0)
        #expect(reading.instantAmperageMA == 0)
        #expect(reading.adapterWatts == nil)
        #expect(reading.healthFraction == nil)
    }

    @Test("A domain reply without the two required keys is an error, not a zero reading")
    func rejectsIncompleteDomain() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["ExternalConnected": true] as [String: Any], format: .xml, options: 0
        )
        #expect(throws: BatteryParseError.missingKey("BatteryCurrentCapacity")) {
            try BatteryPlistParser.parseBatteryDomain(data, deviceID: "udid")
        }
    }

    @Test("Merging a partial keeps the full reading's detail and takes only the four fields")
    func merging() throws {
        let full = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneChargingUSB.data, deviceID: "phone", name: "iPhone",
            transport: .wifi, timestamp: referenceDate
        )
        let partial = try BatteryPlistParser.parseBatteryDomain(
            try batteryDomainPlist(percent: full.percent + 5, charging: true),
            deviceID: "phone", name: "iPhone", viaDirect: true,
            timestamp: referenceDate.addingTimeInterval(180)
        )
        let merged = full.updated(withPartial: partial)

        #expect(merged.percent == full.percent + 5)
        #expect(merged.isPartial)
        #expect(merged.viaDirect)
        #expect(merged.timestamp == referenceDate.addingTimeInterval(180))
        // Detail survives untouched, which is exactly what detailAge is for.
        #expect(merged.rawMaxMAh == full.rawMaxMAh)
        #expect(merged.instantAmperageMA == full.instantAmperageMA)
        #expect(merged.adapterWatts == full.adapterWatts)
        #expect(merged.temperatureC == full.temperatureC)
    }

    @Test("The estimator refuses partial readings so its EMA is not dragged to zero")
    func estimatorIgnoresPartials() throws {
        var estimator = ChargeEstimator()
        let full = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneChargingUSB.data, deviceID: "phone", name: "iPhone",
            transport: .wifi, timestamp: referenceDate
        )
        let seeded = estimator.ingest(full)
        #expect(seeded.etaTo80 != nil)
        let ema = try #require(estimator.smoothedCurrentMA["phone"])

        let partial = BatteryReading.partial(
            deviceID: "phone", name: "iPhone", percent: 70,
            isCharging: true, externalConnected: true, timestamp: referenceDate
        )
        let estimate = estimator.ingest(partial)

        #expect(estimator.smoothedCurrentMA["phone"] == ema)
        #expect(estimate.smoothedCurrentMA == ema)
        #expect(estimate.etaTo80 == nil)
        #expect(estimate.timeToEmpty == nil)
        #expect(estimate.chargingWatts == nil)
    }

    @Test("A reading JSON with no isPartial key decodes as false")
    func decodesLegacyJSON() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try JSONSerialization.jsonObject(
            with: try encoder.encode(
                BatteryReading.partial(
                    deviceID: "u", name: "iPhone", percent: 50,
                    isCharging: true, externalConnected: true, timestamp: referenceDate
                )
            )
        ) as! [String: Any]
        #expect(object["isPartial"] as? Bool == true)
        object.removeValue(forKey: "isPartial")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            BatteryReading.self, from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(!decoded.isPartial)
        #expect(decoded.percent == 50)
    }

    @Test("A partial status renders as partial with the age of its detail")
    func formatting() throws {
        let full = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneChargingUSB.data, deviceID: "phone", name: "iPhone",
            transport: .wifi, timestamp: referenceDate
        )
        var estimator = ChargeEstimator()
        let estimate = estimator.ingest(full)
        let partial = BatteryReading.partial(
            deviceID: "phone", name: "iPhone", percent: 33,
            isCharging: true, externalConnected: true,
            timestamp: referenceDate.addingTimeInterval(180)
        )
        let status = DeviceStatus(
            reading: full.updated(withPartial: partial),
            estimate: estimate,
            lastSeen: referenceDate.addingTimeInterval(180),
            detailAge: 180
        )
        let line = StatusFormatter.line(for: status, now: referenceDate.addingTimeInterval(180))
        #expect(line.contains("33 %"))
        #expect(line.contains("partial"))
        #expect(line.contains("detail 3m ago"))
    }

    @Test("A partial with no full reading behind it prints no watts at all")
    func baselessPartialHidesUnknowns() {
        let partial = BatteryReading.partial(
            deviceID: "phone", name: "iPhone", percent: 99,
            isCharging: false, externalConnected: false, timestamp: referenceDate
        )
        let status = DeviceStatus(reading: partial, lastSeen: referenceDate)
        let line = StatusFormatter.line(for: status, now: referenceDate)
        // 0 mW is "unknown", not "nothing is flowing" — never render it.
        #expect(!line.contains("W"))
        #expect(line == "iPhone  99 %  discharging  wifi  partial")
    }

    @Test("Compact ages read the way the CLI prints them")
    func compactAges() {
        #expect(StatusFormatter.compactAge(0) == "0s")
        #expect(StatusFormatter.compactAge(45) == "45s")
        #expect(StatusFormatter.compactAge(180) == "3m")
        #expect(StatusFormatter.compactAge(3720) == "1h 02m")
    }
}

// MARK: - Typed errors

@Suite("MonitorError")
struct MonitorErrorTests {

    @Test("Read failures map onto cases the UI can branch on")
    func classification() {
        #expect(MonitorError(PhoneError.noDevice(udid: "u")) == .noDevice)
        #expect(MonitorError(PhoneError.notPaired(code: -21)).localizedKey == "tandem.error.notPaired")
        #expect(MonitorError(PhoneError.serviceFailed(code: -27)).localizedKey == "tandem.error.relayRefused")
        #expect(MonitorError(DirectLockdownError.noAddress(udid: "u")) == .noAddress)
        #expect(
            MonitorError(DirectLockdownError.noPairRecord(udid: "u", code: -1)).localizedKey
                == "tandem.error.notPaired"
        )
        // A connect timeout is the radio being off; a later one is not.
        #expect(
            MonitorError(DirectLockdownError.timedOut(step: "connect 1.2.3.4:62078", after: 8))
                .localizedKey == "tandem.error.unreachable"
        )
        #expect(
            MonitorError(DirectLockdownError.timedOut(step: "IORegistry", after: 8))
                == .timedOut(seconds: 8)
        )
        #expect(MonitorError(CancellationError()) == .cancelled)
        #expect(MonitorError(BatteryParseError.notADictionary).localizedKey
            == "tandem.error.malformedResponse")
    }

    @Test("Only a missing pairing is permanent")
    func transience() {
        #expect(MonitorError.noDevice.isTransient)
        #expect(MonitorError.relayRefused().isTransient)
        #expect(MonitorError.unreachable().isTransient)
        #expect(!MonitorError.notPaired().isTransient)
    }

    @Test("Every case has a distinct, stable localizedKey")
    func keysAreDistinct() {
        let all: [MonitorError] = [
            .noDevice, .notPaired(), .unreachable(), .timedOut(seconds: 1), .noAddress,
            .relayRefused(), .malformedResponse(), .macReadFailed(), .cancelled, .other(detail: "x"),
        ]
        #expect(Set(all.map(\.localizedKey)).count == all.count)
        #expect(all.allSatisfy { $0.localizedKey.hasPrefix("tandem.error.") })
    }

    @Test("It round-trips through JSON, and an unknown kind degrades to .other")
    func codable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for error in [
            MonitorError.noDevice,
            .notPaired(detail: "trust not granted"),
            .timedOut(seconds: 8),
            .relayRefused(detail: "eof"),
            .other(detail: "boom"),
        ] {
            #expect(try decoder.decode(MonitorError.self, from: try encoder.encode(error)) == error)
        }

        let future = try JSONSerialization.data(withJSONObject: ["kind": "somethingNew"])
        #expect(try decoder.decode(MonitorError.self, from: future) == .other(detail: "somethingNew"))
    }

    @Test("Snapshots carry the typed error and stay loadable without one")
    func travelsInSnapshots() async throws {
        let reading = try BatteryPlistParser.parseIPhone(
            Fixture.iphoneChargingWiFi.data, deviceID: "phone", name: "iPhone",
            transport: .wifi, timestamp: referenceDate
        )
        let snapshot = TandemSnapshot(
            generatedAt: referenceDate,
            phone: DeviceStatus(reading: reading, lastSeen: referenceDate, error: .relayRefused(detail: "eof")),
            phoneError: .relayRefused(detail: "eof")
        )
        let store = SnapshotStore(url: URL(fileURLWithPath: "/dev/null"))
        let data = try await store.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode(TandemSnapshot.self, from: data) == snapshot)

        // A snapshot written before any of this existed still loads.
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object.removeValue(forKey: "phoneError")
        var phone = object["phone"] as! [String: Any]
        phone.removeValue(forKey: "error")
        phone.removeValue(forKey: "detailAge")
        object["phone"] = phone
        let legacy = try decoder.decode(
            TandemSnapshot.self, from: try JSONSerialization.data(withJSONObject: object)
        )
        #expect(legacy.phoneError == nil)
        #expect(legacy.phone?.error == nil)
        #expect(legacy.phone?.detailAge == nil)
        #expect(legacy.phone?.reading.percent == snapshot.phone?.reading.percent)
    }
}

// MARK: - Runtime reconfiguration

@Suite("Monitor runtime reconfiguration")
struct MonitorReconfigurationTests {

    /// A monitor with no store and no loops running: `update` and friends are
    /// pure actor state changes, so they are checkable without a device.
    private func monitor() -> TandemMonitor {
        TandemMonitor(store: nil, configuration: TandemMonitor.Configuration(staleAfter: 42))
    }

    @Test("update(configuration:) replaces settings in place")
    func updatesInPlace() async {
        let monitor = self.monitor()
        #expect(await monitor.configuration.staleAfter == 42)

        var updated = await monitor.configuration
        updated.staleAfter = 300
        updated.estimatorAlpha = 0.5
        await monitor.update(configuration: updated)

        #expect(await monitor.configuration.staleAfter == 300)
        #expect(await monitor.configuration.estimatorAlpha == 0.5)
    }

    @Test("The single-setting setters change one thing and leave the rest alone")
    func setters() async {
        let monitor = self.monitor()
        let before = await monitor.configuration

        await monitor.setPreferNetworkTransport(true)
        await monitor.setUseDirectClient(false)
        await monitor.setPolicy(PollingPolicy(chargingInterval: 5, dischargingInterval: 7))

        let after = await monitor.configuration
        #expect(after.preferNetworkTransport)
        #expect(!after.useDirectClient)
        #expect(after.policy.chargingInterval == 5)
        #expect(after.policy.dischargingInterval == 7)
        #expect(after.staleAfter == before.staleAfter)
        #expect(after.directOnly == before.directOnly)
    }

    @Test("A boost clips the interval to 15 s and expires on its own")
    func boosting() async {
        let monitor = TandemMonitor(
            store: nil,
            configuration: TandemMonitor.Configuration(boostedInterval: 15, boostDuration: 0.2)
        )
        #expect(!(await monitor.isBoosted))

        await monitor.setBoosted(true)
        #expect(await monitor.isBoosted)

        try? await Task.sleep(for: .milliseconds(400))
        #expect(!(await monitor.isBoosted))
    }

    @Test("setBoosted(false) clears immediately")
    func unboosting() async {
        let monitor = self.monitor()
        await monitor.setBoosted(true)
        #expect(await monitor.isBoosted)
        await monitor.setBoosted(false)
        #expect(!(await monitor.isBoosted))
    }

    @Test("requestRefresh coalesces: many calls do not queue many polls")
    func refreshCoalesces() async {
        // AsyncSignal is the coalescing primitive; a burst of signals leaves one
        // pending wake, not one per call.
        let signal = AsyncSignal()
        for _ in 0..<50 { signal.signal() }
        let started = Date()
        await signal.sleep(seconds: 30)
        #expect(Date().timeIntervalSince(started) < 5)
        // The second sleep is not short-circuited: the burst was one wake.
        let second = Date()
        await signal.sleep(seconds: 0.2)
        #expect(Date().timeIntervalSince(second) >= 0.15)

        // And the monitor's own entry point does not trap or block.
        let monitor = self.monitor()
        for _ in 0..<10 { await monitor.requestRefresh() }
    }
}
