import Foundation
import os

/// Reads the snapshot the app publishes into *this extension's* sandbox
/// container.
///
/// There is no signing identity on this machine (`security find-identity -v -p
/// codesigning` is empty), so there is no team, so there is no App Group — the
/// usual way an app and its widget share a file is simply unavailable. The
/// workaround (the one AirBattery uses) is the other way round: the widget is
/// sandboxed, so `.documentDirectory` resolves inside
/// `~/Library/Containers/dev.tandem.app.widget/Data/Documents`, and the
/// *unsandboxed* app writes the file there directly. Nothing here has to know
/// that path — `FileManager` hands us whatever the container really is, which
/// is also what gets logged below so the app's guess can be checked against it.
enum SnapshotLoader {

    static let log = Logger(subsystem: "dev.tandem", category: "widget")

    static let fileName = "snapshot.json"

    /// `<container>/Data/Documents/snapshot.json` when sandboxed.
    static var containerURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The app's own unsandboxed file. Only readable if this extension somehow
    /// runs unsandboxed; harmless (and denied) otherwise. `NSHomeDirectoryForUser`
    /// rather than `FileManager.homeDirectoryForCurrentUser`, because the latter
    /// answers with the container once the sandbox is on.
    static var appSupportURL: URL? {
        guard let home = NSHomeDirectoryForUser(NSUserName()) else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Tandem", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Same settings `BatteryCore.SnapshotStore` encodes with — ISO-8601 dates,
    /// everything else stock.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let logOnce: Void = {
        log.notice("widget documents dir: \(containerURL?.path ?? "<none>", privacy: .public)")
        log.notice("widget home: \(NSHomeDirectory(), privacy: .public)")
    }()

    /// `<container>/Data/Documents/widget-activity.json` — the breadcrumb the
    /// app reads to find out that a widget is placed and being refreshed.
    static var activityMarkerURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(WidgetActivityMarker.fileName, isDirectory: false)
    }

    /// Drop the breadcrumb. Called from every timeline request — which only
    /// happens for a widget that is actually placed somewhere, since WidgetKit
    /// never runs the provider of a widget nobody has added.
    ///
    /// Failures are logged and swallowed: a missing marker costs the app a
    /// slower poll cadence, never a wrong reading.
    static func markVisible(family: String, now: Date = Date()) {
        guard let url = activityMarkerURL else { return }
        do {
            try WidgetActivityMarker.write(WidgetActivityMarker(requestedAt: now, family: family), to: url)
        } catch {
            log.error("activity marker write failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func load() -> TandemSnapshot? {
        _ = logOnce
        for url in [containerURL, appSupportURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let snapshot = try decoder.decode(TandemSnapshot.self, from: data)
                log.notice("read snapshot from \(url.path, privacy: .public)")
                return snapshot
            } catch {
                log.error("decode failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
        log.notice("no snapshot found")
        return nil
    }
}
