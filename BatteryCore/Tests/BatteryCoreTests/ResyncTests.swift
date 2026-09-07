import Foundation
import Testing
@testable import BatteryCore

// MARK: - Fakes

/// Records every step a `ResyncSequence` takes, in order, and lets each one be
/// made to succeed or fail. No usbmuxd, no socket, no phone.
actor FakeResyncTransports {

    enum ReadBehaviour: Sendable {
        case succeeds(percent: Int)
        case unreachable
    }

    private(set) var steps: [ResyncSequence.Step] = []
    /// The udid the read was actually asked for, so "the read used what
    /// *discovery* found, not what was on file" is assertable.
    private(set) var readDevices: [PhoneDevice] = []

    private let forgotten: [String]
    private let discovered: [PhoneDevice]
    private let behaviour: ReadBehaviour

    init(
        forgotten: [String] = ["udid-old"],
        discovered: [PhoneDevice] = [PhoneDevice(udid: "udid-new", name: "iPhone", transport: .wifi)],
        read: ReadBehaviour = .succeeds(percent: 61)
    ) {
        self.forgotten = forgotten
        self.discovered = discovered
        self.behaviour = read
    }

    func forget() -> [String] {
        steps.append(.forgetAddresses)
        return forgotten
    }

    func dropSessions() {
        steps.append(.dropSessions)
    }

    func resetBackoff() {
        steps.append(.resetBackoff)
    }

    func discover() -> [PhoneDevice] {
        steps.append(.discover)
        return discovered
    }

    func read(_ device: PhoneDevice) throws -> BatteryReading {
        steps.append(.read)
        readDevices.append(device)
        switch behaviour {
        case .succeeds(let percent):
            return makeReading(percent: percent)
        case .unreachable:
            throw MonitorError.unreachable(detail: "connect timed out")
        }
    }

    func run() async -> ResyncOutcome {
        await ResyncSequence().run(
            forgetAddresses: { await self.forget() },
            dropSessions: { await self.dropSessions() },
            resetBackoff: { await self.resetBackoff() },
            discover: { await self.discover() },
            read: { try await self.read($0) }
        )
    }
}

// MARK: - The sequence

@Suite("Resync")
struct ResyncTests {

    @Test("The address goes before discovery does, so the next read cannot dial the old one")
    func orderIsForgetThenDiscoverThenRead() async {
        let fakes = FakeResyncTransports()
        let outcome = await fakes.run()

        // The ordering *is* the feature: forgetting after discovery would leave
        // the direct client dialling the address that stopped answering.
        #expect(await fakes.steps == [.forgetAddresses, .dropSessions, .resetBackoff, .discover, .read])
        #expect(outcome.steps == [.forgetAddresses, .dropSessions, .resetBackoff, .discover, .read])
        // And the read went to the device discovery named, not to the one that
        // was on file a moment ago.
        #expect(await fakes.readDevices.map(\.udid) == ["udid-new"])
        #expect(outcome.forgotten == ["udid-old"])
        #expect(outcome.found)
        #expect(outcome.discovered)
        #expect(outcome.reading?.percent == 61)
    }

    @Test("A phone usbmuxd cannot see at all is reported as not found, and no read is attempted")
    func noDeviceIsReportedNotFound() async {
        let fakes = FakeResyncTransports(discovered: [])
        let outcome = await fakes.run()

        #expect(await fakes.steps == [.forgetAddresses, .dropSessions, .resetBackoff, .discover])
        #expect(await fakes.readDevices.isEmpty)
        #expect(!outcome.discovered)
        #expect(!outcome.found)
        #expect(outcome.error == .noDevice)
    }

    @Test("Discovered but silent: the addresses are still gone, and the error survives")
    func discoveredButUnreachable() async {
        let fakes = FakeResyncTransports(read: .unreachable)
        let outcome = await fakes.run()

        #expect(outcome.discovered)
        #expect(!outcome.found)
        #expect(outcome.forgotten == ["udid-old"])
        #expect(outcome.error?.localizedKey == "tandem.error.unreachable")
        #expect(outcome.summary.contains("discovered, unreachable"))
    }

    @Test("The backoff step really is one of the steps, and resets the unreachable ladder")
    func backoffResetIsPartOfTheSequence() async {
        let fakes = FakeResyncTransports()
        let outcome = await fakes.run()
        #expect(outcome.steps.contains(.resetBackoff))

        // What zeroing the counter is worth: the ladder's fourth rung is ten
        // minutes, the zeroth is the level's own cadence.
        let policy = PollingPolicy()
        #expect(policy.backoff(4) == 600)
        let stuck = policy.phoneDelay(level: .background, state: .unreachable, consecutiveFailures: 4)
        let reset = policy.phoneDelay(level: .background, state: .unreachable, consecutiveFailures: 0)
        #expect(stuck == 600)
        #expect(reset == policy.backgroundDischargingInterval)
        #expect((reset ?? 0) < (stuck ?? 0))
    }
}

// MARK: - The address book

@Suite("Address book forgetting")
struct AddressBookForgetTests {

    private func temporaryFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tandem-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(PhoneAddressBook.fileName)
    }

    @Test("forgetAll empties the file and names what it forgot")
    func forgetAllClearsEveryAddress() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = PhoneAddressBook(fileURL: url)
        await book.record(udid: "udid-a", host: "192.0.2.10", name: "iPhone")
        await book.record(udid: "udid-b", host: "fe80::1%en0")
        #expect(await book.all().count == 2)

        let forgotten = await book.forgetAll()
        #expect(forgotten == ["udid-a", "udid-b"])
        #expect(await book.all().isEmpty)
        #expect(await book.address(for: "udid-a") == nil)

        // And it is gone from disk, not just from the in-memory cache: a fresh
        // book over the same file must not resurrect the address.
        let reopened = PhoneAddressBook(fileURL: url)
        #expect(await reopened.all().isEmpty)

        // Idempotent — a second Resync with nothing on file forgets nothing.
        #expect(await book.forgetAll().isEmpty)
    }

    @Test("PhoneBatterySource.forgetAddresses clears the book it was given")
    func sourceForgetsThroughItsBook() async throws {
        let url = temporaryFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let book = PhoneAddressBook(fileURL: url)
        await book.record(udid: "udid-a", host: "192.0.2.10")
        let source = PhoneBatterySource(addressBook: book)

        #expect(await source.knownHost(for: "udid-a") == "192.0.2.10")
        let forgotten = await source.forgetAddresses()
        #expect(forgotten == ["udid-a"])
        #expect(await source.knownHost(for: "udid-a") == nil)
        #expect(await source.knownHosts(for: "udid-a").isEmpty)
    }
}
