import Foundation

/// A decode-only stand-in for `BatteryCore.MonitorError`.
///
/// The widget compiles `BatteryCore/Models.swift` and
/// `BatteryCore/TandemSnapshot.swift` straight from the package (see
/// `project.yml`) so `TandemSnapshot` here is literally the same source of
/// truth as the app's. It deliberately does **not** compile
/// `BatteryCore/MonitorError.swift`, because that file reaches into
/// `PhoneError` / `DirectLockdownError` / `BatteryParseError`, which drag in
/// the whole libimobiledevice half of the package — dylibs from
/// `/opt/homebrew` that a sandboxed extension cannot load.
///
/// `DeviceStatus.error` is the only thing that needs the type, and the widget
/// never renders it, so this shim only has to satisfy the conformances
/// `DeviceStatus` synthesises and to survive round-tripping whatever the real
/// enum wrote. It matches the real `Codable` shape (`kind` / `detail` /
/// `seconds`) and keeps unknown kinds verbatim, so a case added to BatteryCore
/// later still decodes here instead of failing the whole snapshot.
public struct MonitorError: Error, Sendable, Codable, Equatable, CustomStringConvertible {
    public var kind: String
    public var detail: String?
    public var seconds: TimeInterval?

    private enum CodingKeys: String, CodingKey { case kind, detail, seconds }

    public var description: String {
        guard let detail, !detail.isEmpty else { return kind }
        return "\(kind): \(detail)"
    }
}
