import Foundation

/// Writes iCloudy's JSON stores off the main thread.
///
/// The queue, the mirrors and the offline copies used to encode and write their whole file on the main actor, every
/// couple of seconds while anything was transferring; with a long history in the queue that was a visible stutter.
/// Every file has a serial queue of its own, so writes of one file land in the order they were asked for while a big
/// store being written never holds up a small one. A write that can wait (`later`) is dropped if a newer one for the
/// same file arrives before it runs, so a burst of changes costs one write. A write that cannot (`now`) waits for the
/// earlier writes of its own file only, and reports its error to the caller, as `LocalStore.save` did.
final class StoreWriter: @unchecked Sendable {
    static let shared = StoreWriter()

    private let lock = NSLock()
    /// One serial queue per file. Ordering only matters within a file: two stores never read each other's bytes.
    private var queues: [URL: DispatchQueue] = [:]
    /// The newest generation asked for, per file. A write older than this when its turn comes is skipped.
    private var newest: [URL: UInt64] = [:]
    private var counter: UInt64 = 0

    private func stamp(_ url: URL) -> (UInt64, DispatchQueue) {
        lock.withLock {
            counter += 1; newest[url] = counter
            return (counter, queueLocked(url))
        }
    }
    private func queueLocked(_ url: URL) -> DispatchQueue {
        if let queue = queues[url] { return queue }
        let queue = DispatchQueue(label: "dev.icloudy.store-writer." + url.lastPathComponent, qos: .utility)
        queues[url] = queue
        return queue
    }
    private func isNewest(_ generation: UInt64, _ url: URL) -> Bool { lock.withLock { newest[url] == generation } }

    /// Encodes and writes in the background. `failed` runs on the main actor when the write fails.
    func later<T: Encodable & Sendable>(_ value: T, to url: URL, failed: @escaping @MainActor @Sendable (Error) -> Void = { _ in }) {
        let (generation, queue) = stamp(url)
        queue.async { [self] in
            guard isNewest(generation, url) else { return }
            do { try LocalStore.save(value, to: url) }
            catch { Task { @MainActor in failed(error) } }
        }
    }

    /// Writes before returning, after every earlier write of the same file, and throws what went wrong.
    func now<T: Encodable & Sendable>(_ value: T, to url: URL) throws {
        let (generation, queue) = stamp(url)
        try queue.sync { [self] in
            guard isNewest(generation, url) else { return }
            try LocalStore.save(value, to: url)
        }
    }

    /// Writes in this file's turn and returns once the bytes are on disk, without holding the caller's thread. Never
    /// skipped for a newer write: whoever waits for this is about to act on the state being durable.
    func write<T: Encodable & Sendable>(_ value: T, to url: URL) async throws {
        let (_, queue) = stamp(url)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do { try LocalStore.save(value, to: url); continuation.resume() }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Runs `work` in this file's turn. A seam for tests that need a file's queue to be busy.
    func enqueue(on url: URL, _ work: @escaping @Sendable () -> Void) {
        lock.withLock { queueLocked(url) }.async(execute: work)
    }

    /// Waits for every write of this file asked for so far, as a read of it must.
    func flush(_ url: URL) {
        let queue = lock.withLock { queues[url] }
        queue?.sync {}
    }

    /// Waits for every write asked for so far, of any file. Called before the process exits.
    func flush() {
        for queue in lock.withLock({ Array(queues.values) }) { queue.sync {} }
    }
}
