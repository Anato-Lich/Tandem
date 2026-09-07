import Foundation

/// The breadcrumb a widget extension drops every time WidgetKit asks it for a
/// timeline, so the app can tell "a widget is on screen somewhere" from "no
/// widget has been looked at in an hour". See NOTES.md §14.
///
/// There is no API that answers "is my widget placed and visible": WidgetKit
/// only ever *asks*, and it asks a placed widget on its own schedule. A
/// timeline request within the last `freshnessWindow` is therefore the only
/// evidence available, and it is good evidence — an unplaced widget's provider
/// is never run at all.
///
/// Deliberately Foundation-only: this file is compiled into the sandboxed
/// widget extension as well as into BatteryCore, and the extension cannot load
/// the libimobiledevice chain the rest of the package links.
public struct WidgetActivityMarker: Codable, Sendable, Equatable {

    /// The file both sides agree on, inside the widget extension's own
    /// container `Documents` directory (the same trick `snapshot.json` uses:
    /// the extension is sandboxed and the app is not, so the app can write and
    /// read there while the extension just sees its own Documents folder).
    public static let fileName = "widget-activity.json"

    /// A marker older than this is ignored. WidgetKit refreshes a placed
    /// widget far more often than this in practice; 10 minutes is loose enough
    /// to survive a throttled refresh and tight enough that a widget removed
    /// from the desktop stops costing phone polls within one cadence.
    public static let freshnessWindow: TimeInterval = 600

    /// When the timeline was requested.
    public var requestedAt: Date
    /// `"small"` or `"medium"` — which family asked. Informational; the
    /// scheduling decision does not depend on it.
    public var family: String

    public init(requestedAt: Date = Date(), family: String) {
        self.requestedAt = requestedAt
        self.family = family
    }

    /// Pure: is this marker recent enough to count as "a widget is on screen"?
    ///
    /// A marker dated in the future (clock changes, a file copied across
    /// machines) counts as fresh rather than as an error — the only thing it
    /// can cost is one extra poll.
    public func isFresh(now: Date = Date(), within window: TimeInterval = WidgetActivityMarker.freshnessWindow) -> Bool {
        now.timeIntervalSince(requestedAt) < window
    }

    /// Age in seconds, never negative.
    public func age(now: Date = Date()) -> TimeInterval {
        max(0, now.timeIntervalSince(requestedAt))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ marker: WidgetActivityMarker) throws -> Data {
        try encoder.encode(marker)
    }

    public static func decode(_ data: Data) throws -> WidgetActivityMarker {
        try decoder.decode(WidgetActivityMarker.self, from: data)
    }

    /// Write the marker, creating the directory if the container is new.
    /// Failures are swallowed by design at the call site in the widget: a
    /// missing breadcrumb costs a slower poll, never a wrong reading.
    public static func write(_ marker: WidgetActivityMarker, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encode(marker).write(to: url, options: [.atomic])
    }

    /// `nil` when the file is missing or unreadable, which is the normal state
    /// on a Mac with no widget placed.
    public static func read(from url: URL) -> WidgetActivityMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }
}
