import Foundation

/// Writes iCloudy's JSON stores off the main thread.
///
/// The queue, the mirrors and the offline copies used to encode and write their whole file on the main actor, every
/// couple of seconds while anything was transferring; with a long history in the queue that was a visible stutter.
/// Here every write goes through one serial queue, in the order it was asked for. A write that can wait (`later`)
/// is dropped if a newer one for the same file arrives before it runs, so a burst of changes costs one write. A write
/// that cannot (`now`) waits for everything before it and reports its error to the caller, as `LocalStore.save` did.
final class StoreWriter: @unchecked Sendable {
    static let shared = StoreWriter()

    private let queue = DispatchQueue(label: "dev.icloudy.store-writer", qos: .utility)
    private let lock = NSLock()
    /// The newest generation asked for, per file. A write older than this when its turn comes is skipped.
    private var newest: [URL: UInt64] = [:]
    private var counter: UInt64 = 0

    private func stamp(_ url: URL) -> UInt64 {
        lock.withLock { counter += 1; newest[url] = counter; return counter }
    }
    private func isNewest(_ generation: UInt64, _ url: URL) -> Bool { lock.withLock { newest[url] == generation } }

    /// Encodes and writes in the background. `failed` runs on the main actor when the write fails.
    func later<T: Encodable & Sendable>(_ value: T, to url: URL, failed: @escaping @MainActor @Sendable (Error) -> Void = { _ in }) {
        let generation = stamp(url)
        queue.async { [self] in
            guard isNewest(generation, url) else { return }
            do { try LocalStore.save(value, to: url) }
            catch { Task { @MainActor in failed(error) } }
        }
    }

    /// Writes before returning, after every earlier write of any file, and throws what went wrong.
    func now<T: Encodable & Sendable>(_ value: T, to url: URL) throws {
        let generation = stamp(url)
        try queue.sync { [self] in
            guard isNewest(generation, url) else { return }
            try LocalStore.save(value, to: url)
        }
    }

    /// Waits for every write asked for so far. Called before the process exits, and by tests that read a file back.
    func flush() { queue.sync {} }
}
