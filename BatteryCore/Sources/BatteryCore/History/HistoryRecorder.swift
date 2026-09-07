import Foundation

/// Glue between a running `TandemMonitor` and a `HistoryStore`.
///
/// Deliberately one-way and outside the monitor: nothing in `TandemMonitor`
/// knows history exists, so recording can be switched on and off without
/// touching the polling loops.
public enum HistoryRecorder {

    /// Consume `monitor.snapshots()` and record every snapshot.
    ///
    /// Cancel the returned task to stop recording; the stream's
    /// `onTermination` then stops the monitor it started.
    ///
    /// > Important: `snapshots()` **starts its own polling loops**. If the app
    /// > already iterates `snapshots()` for its UI, do not attach a second
    /// > stream — call `store.record(snapshot)` inside the loop it already has
    /// > (`HistoryRecorder.record(_:into:)` does exactly that, with the error
    /// > handling). `attach` is for a process that has no other consumer, which
    /// > is what `tandemctl` and a headless agent look like.
    @discardableResult
    public static func attach(to monitor: TandemMonitor, store: HistoryStore) -> Task<Void, Never> {
        Task {
            for await snapshot in await monitor.snapshots() {
                if Task.isCancelled { return }
                await record(snapshot, into: store)
            }
        }
    }

    /// Record one snapshot, swallowing storage failures.
    ///
    /// History is a nice-to-have: a full disk or a locked database must never
    /// take down the polling loop that feeds the menu bar. The failure is
    /// reported on stderr and the next snapshot tries again.
    public static func record(_ snapshot: TandemSnapshot, into store: HistoryStore) async {
        do {
            try await store.record(snapshot)
        } catch {
            FileHandle.standardError.write(Data("history: \(error)\n".utf8))
        }
    }
}
