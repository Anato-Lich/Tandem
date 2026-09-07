import Foundation

/// The typed failure a `TandemMonitor` surfaces, instead of the
/// `String(describing:)` blob it used to publish.
///
/// Every case carries a stable `localizedKey` so a UI can look up its own
/// wording, plus an optional free-text `detail` for logs. It is `Codable`, so it
/// travels inside `TandemSnapshot` to a widget or an extension; unknown kinds
/// read back as `.other`, which keeps old snapshots loadable when cases are
/// added later.
public enum MonitorError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    /// usbmuxd knows of no such device, and no address is remembered.
    /// Routinely transient over Wi-Fi (NOTES.md §5).
    case noDevice
    /// No pair record, or the user never tapped "Trust This Computer".
    /// The only permanent failure.
    case notPaired(detail: String? = nil)
    /// The phone did not answer at all: connect refused, timed out, radio off.
    case unreachable(detail: String? = nil)
    /// A read exceeded its budget.
    case timedOut(seconds: TimeInterval)
    /// We know nowhere to dial and usbmuxd cannot help (`--direct-only` with an
    /// empty address book).
    case noAddress
    /// The phone answered lockdown but `diagnostics_relay` hung up — the state
    /// the partial tier exists for. If this is the surfaced error, even the
    /// `GetValue` fallback failed too.
    case relayRefused(detail: String? = nil)
    /// The device answered with something we could not decode.
    case malformedResponse(detail: String? = nil)
    /// The Mac's own IOKit read failed.
    case macReadFailed(detail: String? = nil)
    case cancelled
    /// Anything not otherwise classified; `detail` is the original description.
    case other(detail: String)

    // MARK: - Presentation

    /// A stable dot-separated key for localisation. Never changes for a case
    /// once shipped.
    public var localizedKey: String {
        switch self {
        case .noDevice: return "tandem.error.noDevice"
        case .notPaired: return "tandem.error.notPaired"
        case .unreachable: return "tandem.error.unreachable"
        case .timedOut: return "tandem.error.timedOut"
        case .noAddress: return "tandem.error.noAddress"
        case .relayRefused: return "tandem.error.relayRefused"
        case .malformedResponse: return "tandem.error.malformedResponse"
        case .macReadFailed: return "tandem.error.macReadFailed"
        case .cancelled: return "tandem.error.cancelled"
        case .other: return "tandem.error.other"
        }
    }

    /// The free-text half, when there is one. Never shown on its own.
    public var detail: String? {
        switch self {
        case .noDevice, .noAddress, .cancelled:
            return nil
        case .timedOut(let seconds):
            return String(format: "%.1f s", seconds)
        case .notPaired(let detail), .unreachable(let detail), .relayRefused(let detail),
             .malformedResponse(let detail), .macReadFailed(let detail):
            return detail
        case .other(let detail):
            return detail
        }
    }

    /// English fallback wording, used by `tandemctl` and by any UI that has not
    /// localised `localizedKey` yet.
    public var description: String {
        let text: String
        switch self {
        case .noDevice: text = "No device found"
        case .notPaired: text = "Device is not paired or trust was not granted"
        case .unreachable: text = "Could not reach the device"
        case .timedOut(let seconds): return String(format: "Timed out after %.1f s", seconds)
        case .noAddress: text = "No network address is known for this device"
        case .relayRefused: text = "The device answered but diagnostics_relay refused"
        case .malformedResponse: text = "The device's reply could not be decoded"
        case .macReadFailed: text = "The Mac's battery could not be read"
        case .cancelled: text = "Cancelled"
        case .other(let detail): return detail
        }
        guard let detail, !detail.isEmpty else { return text }
        return "\(text): \(detail)"
    }

    /// Worth trying again in a few seconds. Only a missing pairing is not.
    public var isTransient: Bool {
        switch self {
        case .notPaired: return false
        default: return true
        }
    }

    // MARK: - Classification

    /// Map anything thrown by the read paths onto a case.
    public init(_ error: any Error) {
        switch error {
        case let typed as MonitorError:
            self = typed
        case let phone as PhoneError:
            self = MonitorError.from(phone)
        case let direct as DirectLockdownError:
            self = MonitorError.from(direct)
        case let parse as BatteryParseError:
            self = .malformedResponse(detail: parse.description)
        case is CancellationError:
            self = .cancelled
        default:
            self = .other(detail: String(describing: error))
        }
    }

    private static func from(_ error: PhoneError) -> MonitorError {
        switch error {
        case .noDevice: return .noDevice
        case .notPaired: return .notPaired(detail: error.description)
        case .unreachable: return .unreachable(detail: error.description)
        case .timedOut(let seconds): return .timedOut(seconds: seconds)
        case .serviceFailed, .queryFailed, .emptyResponse:
            return .relayRefused(detail: error.description)
        }
    }

    private static func from(_ error: DirectLockdownError) -> MonitorError {
        switch error {
        case .noPairRecord, .malformedPairRecord:
            return .notPaired(detail: error.description)
        case .noAddress:
            return .noAddress
        case .connectFailed:
            return .unreachable(detail: error.description)
        case .timedOut(let step, let seconds):
            // A connect timeout is "the phone is off the air"; anything later is
            // the relay giving up on a phone that *is* answering.
            return step.hasPrefix("connect ")
                ? .unreachable(detail: error.description)
                : .timedOut(seconds: seconds)
        case .ioFailed, .tlsFailed, .protocolError, .lockdownRefused, .emptyResponse:
            return .relayRefused(detail: error.description)
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey { case kind, detail, seconds }

    private var kind: String {
        String(localizedKey.split(separator: ".").last ?? "other")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        if case .timedOut(let seconds) = self {
            try container.encode(seconds, forKey: .seconds)
        } else if let detail {
            try container.encode(detail, forKey: .detail)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail)
        switch kind {
        case "noDevice": self = .noDevice
        case "notPaired": self = .notPaired(detail: detail)
        case "unreachable": self = .unreachable(detail: detail)
        case "timedOut":
            self = .timedOut(seconds: try container.decodeIfPresent(TimeInterval.self, forKey: .seconds) ?? 0)
        case "noAddress": self = .noAddress
        case "relayRefused": self = .relayRefused(detail: detail)
        case "malformedResponse": self = .malformedResponse(detail: detail)
        case "macReadFailed": self = .macReadFailed(detail: detail)
        case "cancelled": self = .cancelled
        default: self = .other(detail: detail ?? kind)
        }
    }
}
