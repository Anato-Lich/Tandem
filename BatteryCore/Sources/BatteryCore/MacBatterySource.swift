import Foundation
import IOKit
import IOKit.ps
import SystemConfiguration

public enum MacBatteryError: Error, Equatable, Sendable, CustomStringConvertible {
    case noBatteryService
    case propertiesUnavailable(kern_return_t)

    public var description: String {
        switch self {
        case .noBatteryService:
            return "No AppleSmartBattery IOService (desktop Mac, or battery removed)"
        case .propertiesUnavailable(let code):
            return "IORegistryEntryCreateCFProperties failed (kern_return_t \(code))"
        }
    }
}

/// Reads this Mac's battery straight out of the IORegistry.
///
/// Nothing is shelled out; `ioreg` is only ever used to produce fixtures.
public actor MacBatterySource {

    private let cachedName: String
    private let cachedID: String

    public init() {
        cachedName = Self.computerName()
        cachedID = Self.platformUUID() ?? "mac"
    }

    /// Snapshot the battery. Cheap (sub-millisecond) — it is a registry read.
    public func read(timestamp: Date = Date()) throws -> BatteryReading {
        let properties = try Self.batteryProperties()
        return try BatteryPlistParser.parse(
            dictionary: properties,
            kind: .mac,
            deviceID: cachedID,
            name: cachedName,
            transport: .local,
            timestamp: timestamp
        )
    }

    /// True when this machine has a battery at all.
    public nonisolated static var hasBattery: Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { return false }
        IOObjectRelease(service)
        return true
    }

    /// Fires whenever IOKit's power-source notification tells us something moved
    /// (plug, unplug, percentage change). Each access returns a fresh stream.
    public nonisolated var events: AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = PowerSourceWatcher(continuation: continuation)
            let thread = Thread {
                if box.attach() {
                    CFRunLoopRun()
                }
                box.detach()
            }
            thread.name = "com.tandem.BatteryCore.power-events"
            thread.stackSize = 128 * 1024
            continuation.onTermination = { _ in box.stop() }
            thread.start()
        }
    }

    // MARK: - IOKit plumbing

    nonisolated static func batteryProperties() throws -> [String: Any] {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != IO_OBJECT_NULL else { throw MacBatteryError.noBatteryService }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        let status = IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0)
        guard status == KERN_SUCCESS, let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            throw MacBatteryError.propertiesUnavailable(status)
        }
        return properties
    }

    nonisolated static func computerName() -> String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String? , !name.isEmpty {
            return name
        }
        if let name = Host.current().localizedName, !name.isEmpty {
            return name
        }
        return "Mac"
    }

    nonisolated static func platformUUID() -> String? {
        let expert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard expert != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(expert) }
        guard let value = IORegistryEntryCreateCFProperty(
            expert, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String else { return nil }
        return value
    }
}

/// Owns an `IOPSNotificationCreateRunLoopSource` on a dedicated run-loop thread
/// and forwards its callbacks into an `AsyncStream`.
///
/// `@unchecked Sendable`: every mutable field is behind `lock`, and the
/// continuation is itself thread safe.
private final class PowerSourceWatcher: @unchecked Sendable {
    private let continuation: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var runLoop: CFRunLoop?
    private var source: CFRunLoopSource?
    private var stopped = false

    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }

    fileprivate func fire() {
        continuation.yield(())
    }

    /// Installs the notification source on the calling thread's run loop.
    /// Returns false when the stream was already torn down or IOKit refused.
    func attach() -> Bool {
        lock.lock()
        if stopped {
            lock.unlock()
            continuation.finish()
            return false
        }
        lock.unlock()

        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let newSource = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(pointer).takeUnretainedValue().fire()
        }, context)?.takeRetainedValue() else {
            continuation.finish()
            return false
        }

        let loop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(loop, newSource, .defaultMode)

        lock.lock()
        source = newSource
        runLoop = loop
        let alreadyStopped = stopped
        lock.unlock()

        if alreadyStopped {
            CFRunLoopRemoveSource(loop, newSource, .defaultMode)
            continuation.finish()
            return false
        }
        return true
    }

    func detach() {
        lock.lock()
        let loop = runLoop
        let src = source
        runLoop = nil
        source = nil
        lock.unlock()
        if let loop, let src {
            CFRunLoopRemoveSource(loop, src, .defaultMode)
        }
        continuation.finish()
    }

    func stop() {
        lock.lock()
        stopped = true
        let loop = runLoop
        lock.unlock()
        if let loop {
            CFRunLoopStop(loop)
        }
    }
}
