import Foundation
import Network

/// Ties the two sources, the estimator, the polling policy and the store
/// together into one loop per device.
///
/// There is no `Timer`: each device loop does `read -> emit -> sleep`, and the
/// sleep is raced against the device's event stream so a plug/unplug wakes it
/// immediately.
///
/// Everything in `Configuration` can be changed while the loops are running
/// (`update(configuration:)` and the single-setting setters); nothing is
/// recreated and no `lastSeen`, reading or EMA history is lost. See NOTES.md §13.
public actor TandemMonitor {

    public struct Configuration: Sendable, Equatable {
        /// How old a reading may get before its `DeviceStatus.isStale` flips.
        public var staleAfter: TimeInterval
        /// Keep publishing the last good reading after a device disappears.
        public var retainLastReading: Bool
        /// Reuse the phone's diagnostics_relay connection between reads.
        public var keepPhoneSessionAlive: Bool
        /// Force the phone to be looked up over Wi-Fi even when USB is present.
        public var preferNetworkTransport: Bool
        /// Try `DirectLockdownClient` (lockdown straight to the phone's IP)
        /// before falling back to usbmuxd. See NOTES.md §12.
        public var useDirectClient: Bool
        /// Direct only, never fall back. Diagnostic; the app should leave this off.
        public var directOnly: Bool
        public var policy: PollingPolicy
        public var estimatorAlpha: Double
        /// The popover cadence. Kept as its own setting for source
        /// compatibility with `setBoosted(_:)`; `PollingPolicy.popoverInterval`
        /// is the same number and is what the schedule actually reads.
        public var boostedInterval: TimeInterval
        /// How long a boost lasts before it clears itself, so a popover that is
        /// never closed cannot poll the phone forever.
        public var boostDuration: TimeInterval

        public init(
            staleAfter: TimeInterval = 180,
            retainLastReading: Bool = true,
            keepPhoneSessionAlive: Bool = false,
            preferNetworkTransport: Bool = false,
            useDirectClient: Bool = true,
            directOnly: Bool = false,
            policy: PollingPolicy = PollingPolicy(),
            estimatorAlpha: Double = 0.3,
            boostedInterval: TimeInterval = 15,
            boostDuration: TimeInterval = 120
        ) {
            self.staleAfter = staleAfter
            self.retainLastReading = retainLastReading
            self.keepPhoneSessionAlive = keepPhoneSessionAlive
            self.preferNetworkTransport = preferNetworkTransport
            self.useDirectClient = useDirectClient
            self.directOnly = directOnly
            self.policy = policy
            self.estimatorAlpha = estimatorAlpha
            self.boostedInterval = boostedInterval
            self.boostDuration = boostDuration
        }
    }

    private let mac: MacBatterySource
    private let phone: PhoneBatterySource
    private let store: SnapshotStore?
    public private(set) var configuration: Configuration

    private var estimator: ChargeEstimator
    private var macStatus: DeviceStatus?
    private var phoneStatus: DeviceStatus?
    /// The last *full* phone reading and when it arrived, so a partial reading
    /// can keep its watts / adapter / ETA basis and `detailAge` can say how old
    /// that basis is.
    private var lastFullPhoneReading: BatteryReading?
    private var lastFullPhoneAt: Date?
    private var emitters: [UUID: AsyncStream<TandemSnapshot>.Continuation] = [:]

    /// One wake signal per loop, owned by the monitor rather than by `run()`, so
    /// `requestRefresh()` and `setBoosted(_:)` can reach them from outside.
    private let macWake = AsyncSignal()
    private let phoneWake = AsyncSignal()

    /// What the UI has told us it is doing. `.background` until the app says
    /// otherwise, which is also what a headless caller (the CLI) stays at.
    public private(set) var activity: ActivityLevel = .background
    /// The level to fall back to when the popover closes — or when its two
    /// minutes run out and nobody told us.
    private var levelBeforePopover: ActivityLevel?
    private var popoverExpiry: Task<Void, Never>?
    /// Consulted on every scheduling decision to raise the level from the
    /// outside. The app points it at the widget's timeline breadcrumb
    /// (`WidgetActivityMarker`); it must be cheap and must not block.
    private var activityFloorProvider: (@Sendable () -> ActivityLevel)?
    /// Set by the events that are worth a read whatever the floor says: a USB
    /// attach, a pairing, or an explicit `requestRefresh()`.
    private var urgentPhoneEvent = false
    /// When the phone was last dialled, for `PollingPolicy.eventFloor`.
    private var lastPhoneAttempt: Date?

    /// How many phone polls in a row have failed — the rung of the unreachable
    /// ladder the loop is on (60 → 120 → 300 → 600 s, NOTES.md §14.2).
    ///
    /// Actor state rather than a local in `phoneLoop` so `resync()` can zero it
    /// from outside: a person asking for a resync has said, in as many words,
    /// that they believe the phone is reachable, and should not have to wait
    /// out a ten-minute backoff to find out.
    public private(set) var phoneFailures = 0
    /// Set by `resync()`: the phone loop drops its cached `PhoneDevice` on the
    /// next turn so the read goes through discovery again.
    private var phoneNeedsRediscovery = false

    /// Phone-request accounting since launch (NOTES.md §14).
    private var statsSince = Date()
    private var phoneAttempts = 0
    private var phoneSuccesses = 0
    private var phoneAttemptsByLevel: [String: Int] = [:]
    private var phoneSuccessesByLevel: [String: Int] = [:]
    private var macReads = 0

    /// Non-fatal problems, surfaced so a CLI or UI can say what went wrong
    /// instead of silently showing nothing.
    ///
    /// These are the legacy `String(describing:)` renderings, kept so existing
    /// call sites keep compiling; prefer `macError` / `phoneError`.
    public private(set) var lastMacError: String?
    public private(set) var lastPhoneError: String?

    /// The typed failures. `nil` when the last poll succeeded.
    public private(set) var macError: MonitorError?
    public private(set) var phoneError: MonitorError?

    public init(
        mac: MacBatterySource = MacBatterySource(),
        phone: PhoneBatterySource = PhoneBatterySource(),
        store: SnapshotStore? = nil,
        configuration: Configuration = Configuration()
    ) {
        self.mac = mac
        self.phone = phone
        self.store = store
        self.configuration = configuration
        self.estimator = ChargeEstimator(alpha: configuration.estimatorAlpha)
    }

    // MARK: - Public surface

    /// The current snapshot, without waiting for the next poll.
    public func snapshot() -> TandemSnapshot {
        let now = Date()
        return TandemSnapshot(
            generatedAt: now,
            mac: macStatus.map { aged($0, now: now, fullAt: nil, error: macError) },
            phone: phoneStatus.map { aged($0, now: now, fullAt: lastFullPhoneAt, error: phoneError) },
            phoneError: phoneError,
            macError: macError
        )
    }

    /// A stream of snapshots. Iterating it starts the polling loops; dropping it
    /// (or breaking out of the `for await`) cancels them.
    public func snapshots() -> AsyncStream<TandemSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(4)) { continuation in
            let token = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.register(token, continuation)
                await self.run()
                await self.unregister(token)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Take one reading from each device and publish it. Used by `tandemctl once`.
    public func pollOnce() async -> TandemSnapshot {
        async let macDone: Void = pollMac()
        async let phoneDone: Void = pollPhone()
        _ = await (macDone, phoneDone)
        let snapshot = self.snapshot()
        await persist(snapshot)
        return snapshot
    }

    /// Runs until cancelled.
    public func run() async {
        let macWake = self.macWake
        let phoneWake = self.phoneWake

        await withTaskGroup(of: Void.self) { group in
            group.addTask { [mac] in
                for await _ in mac.events {
                    if Task.isCancelled { return }
                    macWake.signal()
                }
            }
            group.addTask { [phone] in
                for await event in phone.events {
                    if Task.isCancelled { return }
                    switch event {
                    case .detached:
                        // The Bonjour record going away is not news worth a
                        // read: the read would only fail. NOTES.md §5 — the
                        // record flaps every few tens of seconds over Wi-Fi.
                        continue
                    case .attached(_, .wifi):
                        // The record coming back *is* worth a read, but it is
                        // the flapping half of §5, so it goes through the
                        // event floor rather than round it.
                        phoneWake.signal()
                    case .attached, .paired:
                        // A cable, or a trust prompt answered. Rare, and always
                        // worth reading at once.
                        await self.markUrgentPhoneEvent()
                        phoneWake.signal()
                    }
                }
            }
            group.addTask {
                // A network path change (Wi-Fi joined, VPN up, interface
                // switched) is exactly when a phone that was unreachable
                // becomes reachable again, so it is worth a read at every level
                // but `.hidden` — where the phone loop ignores the wake.
                for await _ in TandemMonitor.networkPathChanges() {
                    if Task.isCancelled { return }
                    macWake.signal()
                    phoneWake.signal()
                }
            }
            group.addTask { await self.macLoop(wake: macWake) }
            group.addTask { await self.phoneLoop(wake: phoneWake) }

            // The three event-forwarding tasks never finish on their own; the
            // loops exit on cancellation, and cancelAll then unblocks them.
            _ = await group.next()
            _ = await group.next()
            group.cancelAll()
            await group.waitForAll()
        }
    }

    // MARK: - Runtime reconfiguration

    /// Replace the whole configuration in place.
    ///
    /// Nothing is torn down: the readings, their `lastSeen`, and the estimator's
    /// EMA all survive (the EMA is carried across even when `estimatorAlpha`
    /// changes). Both loops are woken so the new settings take effect now rather
    /// than at the end of a 120 s sleep.
    public func update(configuration new: Configuration) async {
        let old = configuration
        configuration = new

        if new.estimatorAlpha != old.estimatorAlpha {
            var replacement = ChargeEstimator(alpha: new.estimatorAlpha)
            replacement.seed(estimator.smoothedCurrentMA)
            estimator = replacement
        }
        if new.keepPhoneSessionAlive != old.keepPhoneSessionAlive {
            await phone.setKeepAlive(new.keepPhoneSessionAlive)
        }
        if new.useDirectClient != old.useDirectClient || new.directOnly != old.directOnly {
            await applyDirectPolicy()
        }
        macWake.signal()
        phoneWake.signal()
    }

    /// Change the polling cadence alone.
    public func setPolicy(_ policy: PollingPolicy) async {
        var updated = configuration
        updated.policy = policy
        await update(configuration: updated)
    }

    /// Force (or stop forcing) the Wi-Fi lookup for the phone.
    public func setPreferNetworkTransport(_ enabled: Bool) async {
        var updated = configuration
        updated.preferNetworkTransport = enabled
        await update(configuration: updated)
    }

    /// Turn the direct-by-IP path on or off.
    public func setUseDirectClient(_ enabled: Bool) async {
        var updated = configuration
        updated.useDirectClient = enabled
        await update(configuration: updated)
    }

    /// Poll both devices as soon as the loops can get to it.
    ///
    /// Coalesced: calling it ten times while a poll is in flight produces one
    /// extra poll, not ten, because `AsyncSignal` collapses pending signals.
    /// Safe to call from a UI on every popover open, wake or reachability change.
    public func requestRefresh() {
        // An explicit ask — a wake, a popover, a rising level, the menu's
        // Resync — is never held back by the event floor.
        urgentPhoneEvent = true
        macWake.signal()
        phoneWake.signal()
    }

    /// Forget where the phone lives and look for it again, now.
    ///
    /// `requestRefresh()` only asks the loops to poll sooner; it keeps dialling
    /// the address on file, keeps any relay session open, and stays on whatever
    /// rung of the unreachable ladder it had reached. That is the right default
    /// and the wrong answer for a phone that has moved, changed network or been
    /// re-paired — which is what the menu's "Resync" is for. In order:
    ///
    /// 1. every remembered address is thrown away (`PhoneAddressBook.forgetAll`);
    /// 2. any kept-alive lockdown/diagnostics_relay session is closed;
    /// 3. the unreachable backoff is zeroed and the cached `PhoneDevice` dropped;
    /// 4. the phone is looked for again — usbmuxd's device list first, and the
    ///    neighbour table with it, because the address book is now empty and
    ///    there is nothing for the direct client to dial until discovery has
    ///    written something;
    /// 5. one read is taken over whatever discovery found, and published.
    ///
    /// - Returns: what happened, including whether the phone was found at all.
    ///   Also logged by the caller — `ResyncOutcome.summary` is one line.
    @discardableResult
    public func resync() async -> ResyncOutcome {
        let level = effectiveActivity()
        let useDirect = configuration.useDirectClient
        let preferNetwork = configuration.preferNetworkTransport
        let outcome = await ResyncSequence().run(
            forgetAddresses: { [phone] in await phone.forgetAddresses() },
            dropSessions: { [phone] in await phone.closeAllSessions() },
            resetBackoff: { [weak self] in await self?.resetPhoneBackoff() },
            discover: { [phone] in
                var found = await phone.rediscover()
                if preferNetwork {
                    for index in found.indices { found[index].transport = .wifi }
                }
                return found
            },
            read: { [phone] device in
                try await phone.read(device, useDirectClient: useDirect)
            }
        )

        lastPhoneAttempt = Date()
        recordPhoneAttempt(level)
        if let reading = outcome.reading {
            recordPhoneSuccess(level)
            applyPhone(reading)
            phoneFailures = 0
        } else if let error = outcome.error {
            setPhoneError(error)
        }
        await publish()
        // The read above *was* the immediate poll, so the loops are woken
        // without the urgent flag: they resume at the level's own cadence
        // instead of dialling the phone a second time straight away.
        urgentPhoneEvent = false
        macWake.signal()
        phoneWake.signal()
        return outcome
    }

    /// Back to the bottom rung, and rediscover before the next read.
    private func resetPhoneBackoff() {
        phoneFailures = 0
        phoneNeedsRediscovery = true
    }

    /// Mark the next phone wake as one that skips the event floor.
    private func markUrgentPhoneEvent() {
        urgentPhoneEvent = true
    }

    /// Read and clear the flag.
    private func takeUrgentPhoneEvent() -> Bool {
        defer { urgentPhoneEvent = false }
        return urgentPhoneEvent
    }

    /// Tell the monitor how visible the readout is; this is the whole energy
    /// policy (NOTES.md §14).
    ///
    /// * `.hidden` (display asleep / screen locked) stops phone polling
    ///   entirely — no discovery, no connect, nothing that wakes the phone's
    ///   radio. The Mac keeps its event-driven reads plus a 10-minute sanity
    ///   read, so the label is right the moment the screen comes back.
    /// * `.background` is the menu-bar-only cadence, `.widgetVisible` the one a
    ///   placed widget earns, `.popoverOpen` the 15 s cadence.
    ///
    /// Raising the level polls immediately; lowering it does not, so dropping
    /// out of the popover costs nothing. `.popoverOpen` still clears itself
    /// after `Configuration.boostDuration` (2 minutes) and falls back to
    /// whatever level was in force before it, so a popover left open — or a UI
    /// that forgets — cannot keep the phone awake indefinitely.
    public func setActivity(_ level: ActivityLevel) {
        popoverExpiry?.cancel()
        popoverExpiry = nil
        let previous = activity

        if level == .popoverOpen {
            if previous != .popoverOpen { levelBeforePopover = previous }
            let duration = configuration.boostDuration
            popoverExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                await self?.expirePopover()
            }
        } else {
            levelBeforePopover = nil
        }

        activity = level
        // A rise means somebody just started looking: read now. A fall waits
        // for the sleep already in flight, which is never longer than the
        // cadence we are leaving.
        if level > previous || (level == .popoverOpen && previous == .popoverOpen) {
            requestRefresh()
        }
    }

    /// Legacy shim for the pre-activity API: `true` is `.popoverOpen`, `false`
    /// returns to whatever level was in force before the popover opened
    /// (`.background` if that is unknown).
    public func setBoosted(_ on: Bool) {
        setActivity(on ? .popoverOpen : (levelBeforePopover ?? .background))
    }

    /// True while the popover cadence is in force.
    public var isBoosted: Bool { activity == .popoverOpen }

    /// Install (or clear) the closure consulted on every scheduling decision to
    /// raise the activity level from outside — the app hands it a reader for
    /// the widget's `WidgetActivityMarker`.
    ///
    /// It is called on the actor, once per scheduling decision, so it must be
    /// cheap (a `stat` and a small JSON read at most) and must not block.
    /// `.hidden` is never raised by it: a display that is asleep is not showing
    /// a widget either.
    public func setActivityFloorProvider(_ provider: (@Sendable () -> ActivityLevel)?) {
        activityFloorProvider = provider
    }

    /// The level actually in force: what the UI signalled, raised by the widget
    /// marker, except while `.hidden`.
    public func effectiveActivity() -> ActivityLevel {
        guard activity != .hidden else { return .hidden }
        guard activity != .popoverOpen, let floor = activityFloorProvider?() else { return activity }
        return activity.raised(to: floor)
    }

    private func expirePopover() {
        guard activity == .popoverOpen else { return }
        activity = levelBeforePopover ?? .background
        levelBeforePopover = nil
        popoverExpiry = nil
    }

    // MARK: - Instrumentation

    /// Phone requests attempted and succeeded since launch, broken down by the
    /// activity level they were made at. `tandemctl watch --stats` prints this
    /// every minute; the app logs it hourly.
    public var stats: PollStats {
        PollStats(
            since: statsSince,
            level: effectiveActivity(),
            phoneAttempts: phoneAttempts,
            phoneSuccesses: phoneSuccesses,
            phoneAttemptsByLevel: phoneAttemptsByLevel,
            phoneSuccessesByLevel: phoneSuccessesByLevel,
            macReads: macReads
        )
    }

    private func recordPhoneAttempt(_ level: ActivityLevel) {
        phoneAttempts += 1
        phoneAttemptsByLevel[level.rawValue, default: 0] += 1
    }

    private func recordPhoneSuccess(_ level: ActivityLevel) {
        phoneSuccesses += 1
        phoneSuccessesByLevel[level.rawValue, default: 0] += 1
    }

    // MARK: - Loops

    private func macLoop(wake: AsyncSignal) async {
        var failures = 0
        while !Task.isCancelled {
            let state: PollingPolicy.State
            do {
                let reading = try await mac.read()
                macReads += 1
                let estimate = estimator.ingest(reading)
                macStatus = DeviceStatus(reading: reading, estimate: estimate, lastSeen: reading.timestamp)
                setMacError(nil)
                failures = 0
                state = PollingPolicy.state(for: reading)
            } catch {
                failures += 1
                setMacError(MonitorError(error))
                if !configuration.retainLastReading { macStatus = nil }
                state = .unreachable
            }
            await publish()
            let seconds = configuration.policy.macDelay(
                level: effectiveActivity(),
                state: state,
                consecutiveFailures: failures
            )
            // An event (IOKit power source, network path, `requestRefresh()`)
            // cut the sleep short: the world changed, so the ladder starts over.
            if await wake.sleep(seconds: seconds) { failures = 0 }
        }
    }

    private func phoneLoop(wake: AsyncSignal) async {
        if configuration.keepPhoneSessionAlive {
            await phone.setKeepAlive(true)
        }
        await applyDirectPolicy()
        var known: PhoneDevice?

        while !Task.isCancelled {
            let level = effectiveActivity()
            guard level.pollsPhone else {
                // `.hidden`: the phone is left completely alone. Not a slower
                // cadence — no discovery, no connect, nothing that could wake
                // its radio. We sit on the wake signal instead, so leaving
                // `.hidden` (or any event once we have) polls at once.
                if await wake.sleep(seconds: configuration.policy.hiddenSanityInterval) {
                    phoneFailures = 0
                }
                continue
            }
            // An event brought us here early: honour the level's floor unless
            // this was one of the events that outranks it.
            if let last = lastPhoneAttempt,
               let floor = configuration.policy.eventFloor(level: level),
               !takeUrgentPhoneEvent() {
                let wait = floor - Date().timeIntervalSince(last)
                if wait > 0 {
                    try? await Task.sleep(for: .seconds(wait))
                    // Round again rather than falling through: the level may
                    // have changed while we waited.
                    continue
                }
            }

            // A Resync happened while we were asleep: throw the cached device
            // away so the next turn goes through discovery again.
            if phoneNeedsRediscovery {
                phoneNeedsRediscovery = false
                known = nil
            }

            let state: PollingPolicy.State
            do {
                let device = try await resolvePhone(cached: known)
                known = device
                lastPhoneAttempt = Date()
                recordPhoneAttempt(level)
                let reading = try await phone.read(device, useDirectClient: configuration.useDirectClient)
                recordPhoneSuccess(level)
                applyPhone(reading)
                phoneFailures = 0
                state = PollingPolicy.state(for: reading)
            } catch is CancellationError {
                return
            } catch {
                phoneFailures += 1
                setPhoneError(MonitorError(error))
                // Hold on to the device for one more round: over Wi-Fi, usbmuxd
                // stops listing the phone for minutes at a time while an already
                // open session keeps working. Only re-discover once retrying the
                // known device has also failed.
                if phoneFailures >= 2 { known = nil }
                if !configuration.retainLastReading {
                    phoneStatus = nil
                    lastFullPhoneReading = nil
                    lastFullPhoneAt = nil
                }
                state = .unreachable
            }
            await publish()
            // `nil` only when the level dropped to `.hidden` during the read;
            // the guard at the top of the next turn is what actually stops us.
            let seconds = configuration.policy.phoneDelay(
                level: effectiveActivity(),
                state: state,
                consecutiveFailures: phoneFailures
            ) ?? configuration.policy.hiddenSanityInterval
            // Any event resets the unreachable ladder: a cable, a network path
            // change, a wake, a popover — each is a reason to believe the phone
            // is reachable again, and none of them should have to wait out a
            // 600 s backoff.
            if await wake.sleep(seconds: seconds) { phoneFailures = 0 }
        }
    }

    private func resolvePhone(cached: PhoneDevice?) async throws -> PhoneDevice {
        if let cached { return cached }
        // With the direct path on, a Bonjour blackout must not stop us: ask for
        // remembered addresses too rather than retrying discovery for 6 s.
        let devices = configuration.useDirectClient
            ? await phone.addressableDevices()
            : await phone.discoverWithRetry()
        guard var chosen = devices.first else { throw PhoneError.noDevice(udid: nil) }
        if configuration.preferNetworkTransport { chosen.transport = .wifi }
        return chosen
    }

    // MARK: - Single-device polls (used by pollOnce)

    private func pollMac() async {
        do {
            let reading = try await mac.read()
            macReads += 1
            let estimate = estimator.ingest(reading)
            macStatus = DeviceStatus(reading: reading, estimate: estimate, lastSeen: reading.timestamp)
            setMacError(nil)
        } catch {
            setMacError(MonitorError(error))
        }
    }

    private func applyDirectPolicy() async {
        await phone.setDirectPolicy(
            DirectFirstReader(
                useDirect: configuration.useDirectClient,
                directOnly: configuration.directOnly
            )
        )
    }

    private func pollPhone() async {
        await applyDirectPolicy()
        let level = effectiveActivity()
        do {
            let device = try await resolvePhone(cached: nil)
            lastPhoneAttempt = Date()
            recordPhoneAttempt(level)
            let reading = try await phone.read(device, useDirectClient: configuration.useDirectClient)
            recordPhoneSuccess(level)
            applyPhone(reading)
        } catch {
            setPhoneError(MonitorError(error))
        }
    }

    // MARK: - Reading -> status

    /// Fold a phone reading into `phoneStatus`.
    ///
    /// A **full** reading is the ordinary case: it feeds the estimator and
    /// becomes the new detail basis. A **partial** reading (NOTES.md §13) knows
    /// only percent / charging / external / fullyCharged, so it updates those on
    /// top of the last full reading, keeps that reading's watts, adapter and ETA
    /// untouched, and records how old they now are in `detailAge`. It never
    /// reaches the estimator, whose EMA would otherwise be dragged toward zero
    /// by an amperage the battery domain simply does not report.
    private func applyPhone(_ reading: BatteryReading) {
        defer { setPhoneError(nil) }

        guard reading.isPartial else {
            let estimate = estimator.ingest(reading)
            lastFullPhoneReading = reading
            lastFullPhoneAt = reading.timestamp
            phoneStatus = DeviceStatus(
                reading: reading,
                estimate: estimate,
                lastSeen: reading.timestamp
            )
            return
        }

        guard let basis = lastFullPhoneReading else {
            // Never had a full read: show what we have and admit the rest is
            // unknown rather than inventing zeroes' worth of watts.
            phoneStatus = DeviceStatus(reading: reading, lastSeen: reading.timestamp)
            return
        }

        let merged = basis.updated(withPartial: reading)
        // A plug or unplug since the last full read invalidates every derived
        // number; the percent is still good, the ETA is not.
        let flipped = basis.isCharging != reading.isCharging
            || basis.externalConnected != reading.externalConnected
        let previous = phoneStatus
        phoneStatus = DeviceStatus(
            reading: merged,
            etaTo80: flipped ? nil : previous?.etaTo80,
            timeToEmpty: flipped ? nil : previous?.timeToEmpty,
            chargingWatts: flipped ? nil : previous?.chargingWatts,
            lastSeen: reading.timestamp,
            detailAge: lastFullPhoneAt.map { reading.timestamp.timeIntervalSince($0) },
            // The deadline is absolute, so it is carried across verbatim: a
            // fresher percent must not push "80 % in 12 min" 12 minutes further
            // into the future.
            etaTo80At: flipped ? nil : previous?.etaTo80At
        )
    }

    // MARK: - Plumbing

    private func setMacError(_ error: MonitorError?) {
        macError = error
        lastMacError = error?.description
    }

    private func setPhoneError(_ error: MonitorError?) {
        phoneError = error
        lastPhoneError = error?.description
    }

    private func aged(
        _ status: DeviceStatus,
        now: Date,
        fullAt: Date?,
        error: MonitorError?
    ) -> DeviceStatus {
        var copy = status
        copy.isStale = now.timeIntervalSince(status.lastSeen) > configuration.staleAfter
        if status.reading.isPartial, let fullAt {
            copy.detailAge = now.timeIntervalSince(fullAt)
        }
        copy.error = error
        return copy
    }

    private func register(_ token: UUID, _ continuation: AsyncStream<TandemSnapshot>.Continuation) {
        emitters[token] = continuation
    }

    private func unregister(_ token: UUID) {
        emitters.removeValue(forKey: token)
    }

    private func publish() async {
        let snapshot = self.snapshot()
        for continuation in emitters.values { continuation.yield(snapshot) }
        await persist(snapshot)
    }

    private func persist(_ snapshot: TandemSnapshot) async {
        guard let store else { return }
        try? await store.write(snapshot)
    }
}

// MARK: - Network reachability

extension TandemMonitor {

    /// Path changes from `NWPathMonitor`, as an `AsyncStream` of nudges.
    ///
    /// Coming back onto Wi-Fi, switching interface or dropping a VPN is the
    /// single best predictor that a phone which has been unreachable for
    /// minutes is answering again, and it costs nothing to watch. The first
    /// callback (the path as it already is at subscribe time) is swallowed, so
    /// starting the monitor does not itself look like an event; after that a
    /// nudge is emitted whenever the status or the interface set changes.
    public static func networkPathChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let state = PathState()
            monitor.pathUpdateHandler = { path in
                let fingerprint = "\(path.status)|"
                    + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
                if state.observe(fingerprint) { continuation.yield(()) }
            }
            monitor.start(queue: DispatchQueue(label: "dev.tandem.network-path"))
            continuation.onTermination = { _ in monitor.cancel() }
        }
    }

    /// Remembers the last path fingerprint so the initial callback, and any
    /// repeat of the same path, is not reported as a change.
    private final class PathState: @unchecked Sendable {
        private let lock = NSLock()
        private var last: String?

        /// True when this is a *change* (and not the first observation).
        func observe(_ fingerprint: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            defer { last = fingerprint }
            guard let last else { return false }
            return last != fingerprint
        }
    }
}

// MARK: - Instrumentation

/// Phone-request accounting, since the monitor was created.
///
/// The point of the energy policy is a number — roughly 300 phone requests a
/// day instead of 1400 — so the number is measured rather than assumed.
public struct PollStats: Sendable, Equatable, Codable {
    /// When counting started (monitor creation, i.e. app launch).
    public var since: Date
    /// The activity level in force when the stats were read.
    public var level: ActivityLevel
    public var phoneAttempts: Int
    public var phoneSuccesses: Int
    /// Keyed by `ActivityLevel.rawValue`, so the JSON is a plain object.
    public var phoneAttemptsByLevel: [String: Int]
    public var phoneSuccessesByLevel: [String: Int]
    /// Free by comparison (an in-process IOKit call), counted for context.
    public var macReads: Int

    public init(
        since: Date,
        level: ActivityLevel,
        phoneAttempts: Int,
        phoneSuccesses: Int,
        phoneAttemptsByLevel: [String: Int],
        phoneSuccessesByLevel: [String: Int],
        macReads: Int
    ) {
        self.since = since
        self.level = level
        self.phoneAttempts = phoneAttempts
        self.phoneSuccesses = phoneSuccesses
        self.phoneAttemptsByLevel = phoneAttemptsByLevel
        self.phoneSuccessesByLevel = phoneSuccessesByLevel
        self.macReads = macReads
    }

    public func attempts(at level: ActivityLevel) -> Int {
        phoneAttemptsByLevel[level.rawValue] ?? 0
    }

    public func successes(at level: ActivityLevel) -> Int {
        phoneSuccessesByLevel[level.rawValue] ?? 0
    }

    public func uptime(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(since))
    }

    /// Attempts per day at the rate observed so far. Meaningless in the first
    /// seconds, which is why the summary prints the window alongside it.
    public func projectedPerDay(now: Date = Date()) -> Double {
        let elapsed = uptime(now: now)
        guard elapsed >= 60 else { return 0 }
        return Double(phoneAttempts) * 86_400 / elapsed
    }

    /// One line, for `tandemctl watch --stats` and the app's hourly os_log.
    ///
    /// `phone 12/13 ok  over 21m  ~178/day  level widgetVisible  [hidden 0, background 5, widgetVisible 7, popoverOpen 1]  mac 42`
    public func summary(now: Date = Date()) -> String {
        let byLevel = ActivityLevel.allCases
            .map { "\($0.rawValue) \(attempts(at: $0))" }
            .joined(separator: ", ")
        let rate = projectedPerDay(now: now)
        let rateText = rate > 0 ? String(format: "~%.0f/day", rate) : "~-/day"
        return "phone \(phoneSuccesses)/\(phoneAttempts) ok  over \(StatusFormatter.compactAge(uptime(now: now)))"
            + "  \(rateText)  level \(level.rawValue)  [\(byLevel)]  mac \(macReads)"
    }
}
