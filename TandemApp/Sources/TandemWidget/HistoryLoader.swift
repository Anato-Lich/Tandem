import Foundation

/// Reads `history-summary.json` — the 24 h chart's only source — out of the
/// same place `SnapshotLoader` finds `snapshot.json`.
///
/// The app writes it at most every ten minutes (`HistoryStore.writeSummary`,
/// BatteryCore NOTES.md §15.4) straight into this extension's sandbox
/// container, for the reason spelled out at length in `SnapshotLoader`: no
/// signing identity means no team means no App Group, so the *unsandboxed* app
/// writes into the *sandboxed* extension's Documents directory rather than the
/// other way round.
///
/// `HistorySummary` is not mirrored here: `History/HistoryModels.swift` is
/// Foundation-only, so `TandemApp/project.yml` compiles that very file into
/// this target alongside `Models.swift` and `TandemSnapshot.swift`. The widget
/// therefore decodes the exact type the app encoded, and a field added on one
/// side cannot silently go missing on the other.
enum HistoryLoader {

    static let fileName = "history-summary.json"

    /// `<container>/Data/Documents/history-summary.json` when sandboxed.
    static var containerURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The app's own unsandboxed copy, readable only if this extension somehow
    /// runs outside the sandbox. Same fallback `SnapshotLoader` keeps.
    static var appSupportURL: URL? {
        guard let home = NSHomeDirectoryForUser(NSUserName()) else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Application Support/Tandem", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// Same settings `HistoryStore.encoder` writes with — ISO-8601 dates,
    /// everything else stock.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func load() -> HistorySummary? {
        for url in [containerURL, appSupportURL].compactMap({ $0 }) {
            guard let data = try? Data(contentsOf: url) else { continue }
            do {
                let summary = try decoder.decode(HistorySummary.self, from: data)
                SnapshotLoader.log.notice("read history from \(url.path, privacy: .public)")
                return summary
            } catch {
                SnapshotLoader.log.error(
                    "history decode failed for \(url.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        SnapshotLoader.log.notice("no history summary found")
        return nil
    }
}
