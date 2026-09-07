import Foundation

/// A one-shot-at-a-time wake-up flag: `signal()` releases everyone currently
/// waiting, and a signal that arrives with no waiters is remembered so the next
/// `wait()` returns immediately.
///
/// Used to let event streams cut a scheduled `Task.sleep` short.
final class AsyncSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    func signal() {
        lock.lock()
        let resumable = Array(waiters.values)
        waiters.removeAll()
        if resumable.isEmpty { pending = true }
        lock.unlock()
        for continuation in resumable { continuation.resume() }
    }

    /// Wait for the next signal. Returns early if the task is cancelled.
    func wait() async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if pending || Task.isCancelled {
                    pending = false
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[token] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = waiters.removeValue(forKey: token)
            lock.unlock()
            continuation?.resume()
        }
    }

    private func clearPending() {
        lock.lock()
        pending = false
        lock.unlock()
    }

    /// Sleep for `seconds`, or until `signal()` arrives, whichever is first.
    ///
    /// - Returns: `true` when a signal cut the sleep short (or one was already
    ///   pending), `false` when the full `seconds` elapsed. The monitor uses
    ///   this to tell "an event happened" from "the timer expired", which is
    ///   what resets the unreachable backoff ladder (NOTES.md §14).
    @discardableResult
    func sleep(seconds: TimeInterval) async -> Bool {
        if seconds <= 0 {
            clearPending()
            return false
        }
        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return false
            }
            group.addTask {
                await self.wait()
                return !Task.isCancelled
            }
            let signalled = await group.next() ?? false
            group.cancelAll()
            await group.waitForAll()
            return signalled
        }
    }
}
