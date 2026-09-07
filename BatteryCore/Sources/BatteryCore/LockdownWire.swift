import Foundation

/// Everything that can go wrong on the direct (no-usbmuxd) path.
///
/// Each case names the protocol step it failed at, because the whole reason this
/// client exists is to find out *where* the phone stops answering during a
/// usbmuxd blackout.
public enum DirectLockdownError: Error, Sendable, Equatable, CustomStringConvertible {
    /// usbmuxd has no pairing for this device (or the socket is unreachable).
    case noPairRecord(udid: String, code: Int32)
    case malformedPairRecord(String)
    /// We have never seen this phone on the network, so there is no IP to try.
    case noAddress(udid: String)
    case connectFailed(host: String, port: UInt16, code: Int32)
    /// A step exceeded its own timeout, or the whole attempt exceeded its cap.
    case timedOut(step: String, after: TimeInterval)
    case ioFailed(step: String, detail: String)
    case tlsFailed(step: String, detail: String)
    /// The device answered, but not with what the protocol calls for.
    case protocolError(step: String, detail: String)
    /// lockdownd answered with an `Error` key.
    case lockdownRefused(request: String, error: String)
    case emptyResponse

    public var description: String {
        switch self {
        case .noPairRecord(let udid, let code):
            return "usbmuxd has no pair record for \(udid) (code \(code)); pair the device first"
        case .malformedPairRecord(let detail):
            return "Pair record could not be parsed: \(detail)"
        case .noAddress(let udid):
            return "No cached network address for \(udid)"
        case .connectFailed(let host, let port, let code):
            return "TCP connect to \(host):\(port) failed (errno \(code): \(String(cString: strerror(code))))"
        case .timedOut(let step, let seconds):
            return String(format: "Timed out after %.1f s during %@", seconds, step)
        case .ioFailed(let step, let detail):
            return "I/O failed during \(step): \(detail)"
        case .tlsFailed(let step, let detail):
            return "TLS failed during \(step): \(detail)"
        case .protocolError(let step, let detail):
            return "Unexpected reply during \(step): \(detail)"
        case .lockdownRefused(let request, let error):
            return "lockdownd refused \(request): \(error)"
        case .emptyResponse:
            return "Device returned an empty IORegistry entry"
        }
    }

    /// Which protocol step this failed at, for logging. `nil` for failures that
    /// happen before any bytes move.
    public var step: String? {
        switch self {
        case .timedOut(let step, _), .ioFailed(let step, _),
             .tlsFailed(let step, _), .protocolError(let step, _):
            return step
        case .lockdownRefused(let request, _):
            return request
        case .noPairRecord, .malformedPairRecord, .noAddress, .connectFailed, .emptyResponse:
            return nil
        }
    }

    /// Worth trying again in a few seconds. Only a missing/broken pairing is not.
    public var isTransient: Bool {
        switch self {
        case .noPairRecord, .malformedPairRecord:
            return false
        default:
            return true
        }
    }
}

/// lockdown's framing: a 4-byte big-endian payload length, then a property list.
///
/// We always *send* XML (the device accepts it and it is trivial to build);
/// replies come back as XML from lockdownd itself and as **binary** from
/// diagnostics_relay, so decoding must sniff — `PropertyListSerialization` does
/// that for us.
public enum LockdownWire {

    /// Longest payload we will accept. Real replies are a few tens of kB; this
    /// only exists so a desynchronised stream cannot make us allocate 4 GB.
    public static let maximumPayload = 16 * 1024 * 1024

    public static func encode(_ message: [String: Any]) throws -> Data {
        let payload: Data
        do {
            payload = try PropertyListSerialization.data(
                fromPropertyList: message,
                format: .xml,
                options: 0
            )
        } catch {
            throw DirectLockdownError.protocolError(
                step: "encode",
                detail: error.localizedDescription
            )
        }
        return header(for: payload.count) + payload
    }

    /// The 4-byte big-endian length prefix on its own.
    public static func header(for length: Int) -> Data {
        var big = UInt32(length).bigEndian
        return withUnsafeBytes(of: &big) { Data($0) }
    }

    /// Decode a length prefix. Rejects anything absurd rather than trusting it.
    public static func payloadLength(from header: Data) throws -> Int {
        guard header.count == 4 else {
            throw DirectLockdownError.protocolError(
                step: "read header",
                detail: "expected 4 bytes, got \(header.count)"
            )
        }
        let value = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard value > 0 else {
            throw DirectLockdownError.protocolError(step: "read header", detail: "zero-length payload")
        }
        guard value <= UInt32(maximumPayload) else {
            throw DirectLockdownError.protocolError(
                step: "read header",
                detail: "payload of \(value) B exceeds the \(maximumPayload) B cap"
            )
        }
        return Int(value)
    }

    /// Decode a payload (XML or binary plist) into a dictionary.
    public static func decode(_ payload: Data) throws -> [String: Any] {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: payload, options: [], format: nil)
        } catch {
            throw DirectLockdownError.protocolError(
                step: "decode",
                detail: error.localizedDescription
            )
        }
        guard let dictionary = object as? [String: Any] else {
            throw DirectLockdownError.protocolError(
                step: "decode",
                detail: "payload is a \(type(of: object)), not a dictionary"
            )
        }
        return dictionary
    }

    /// Round-trip helper used by the tests: frame then unframe in one go.
    public static func decodeFramed(_ framed: Data) throws -> [String: Any] {
        guard framed.count >= 4 else {
            throw DirectLockdownError.protocolError(
                step: "read header",
                detail: "only \(framed.count) bytes"
            )
        }
        let length = try payloadLength(from: framed.prefix(4))
        let body = framed.dropFirst(4)
        guard body.count >= length else {
            throw DirectLockdownError.protocolError(
                step: "read payload",
                detail: "header says \(length) B, only \(body.count) B present"
            )
        }
        return try decode(Data(body.prefix(length)))
    }
}
