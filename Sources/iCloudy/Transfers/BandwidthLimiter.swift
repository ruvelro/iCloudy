import Foundation

/// A token bucket shared by every job of the queue that moves bytes in one direction.
///
/// The balance is allowed to go negative: whoever asks takes the bytes at once and is told how long to wait before
/// using them, and the next caller queues behind that debt. Callers do not ask the bucket directly but through a
/// `Lane`, one per job, which always pays whole slices: a job writing 16 KiB at a time and another reading 5 MiB
/// blocks then take turns of the same size, and over a few seconds each gets the same share of the limit.
final class BandwidthLimiter: @unchecked Sendable {
    /// Monotonic seconds. Injectable, so the rate can be measured in tests without waiting for it.
    typealias Clock = @Sendable () -> TimeInterval
    typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    /// One turn. Small enough that concurrent jobs interleave smoothly, large enough that a fast limit does not turn
    /// into thousands of sleeps per second.
    static let slice = 64 * 1024

    private let lock = NSLock()
    private let clock: Clock
    let sleep: Sleep
    private var rate: Double?
    private var tokens: Double = 0
    private var stamp: TimeInterval = 0

    init(clock: @escaping Clock = { ProcessInfo.processInfo.systemUptime },
         sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.clock = clock
        self.sleep = sleep
    }

    /// nil or zero lifts the limit. A new limit starts with a full bucket, so changing it never stalls what is running.
    var bytesPerSecond: Int64? {
        get { lock.withLock { rate.map { Int64($0) } } }
        set {
            lock.withLock {
                let value = newValue.flatMap { $0 > 0 ? Double($0) : nil }
                guard value != rate else { return }
                rate = value
                tokens = value.map(Self.burst) ?? 0
                stamp = clock()
            }
        }
    }
    var isLimited: Bool { lock.withLock { rate != nil } }

    /// What may go out at once after a quiet spell: a quarter of a second, never less than one slice.
    private static func burst(_ rate: Double) -> Double { max(rate / 4, Double(slice)) }

    /// Takes `bytes` from the bucket and returns how many seconds the caller has to wait before sending them.
    func reserve(_ bytes: Int) -> TimeInterval {
        lock.withLock {
            guard let rate, bytes > 0 else { return 0 }
            let now = clock()
            tokens = min(Self.burst(rate), tokens + max(0, now - stamp) * rate)
            stamp = now
            tokens -= Double(bytes)
            return tokens >= 0 ? 0 : -tokens / rate
        }
    }

    /// One job's way into the bucket. It pays a whole slice whenever it runs short and keeps what it did not use for
    /// its next call, so the size of a provider's blocks never decides how much of the limit a job gets.
    final class Lane: @unchecked Sendable {
        let limiter: BandwidthLimiter
        private let lock = NSLock()
        private var credit = 0

        init(_ limiter: BandwidthLimiter) { self.limiter = limiter }
        var isLimited: Bool { limiter.isLimited }

        /// Seconds to wait before `bytes` may go.
        func delay(for bytes: Int) -> TimeInterval {
            lock.withLock {
                guard limiter.isLimited else { credit = 0; return 0 }
                var missing = bytes - credit
                var wait: TimeInterval = 0
                while missing > 0 {
                    wait = limiter.reserve(BandwidthLimiter.slice)
                    missing -= BandwidthLimiter.slice
                }
                credit = -missing
                return wait
            }
        }
        /// Waits until `bytes` may be sent, a slice at a time so other jobs get their turns in between. Cancelling the
        /// task ends the wait at once.
        func acquire(_ bytes: Int) async throws {
            var remaining = bytes
            while remaining > 0, isLimited {
                try Task.checkCancellation()
                let piece = min(remaining, BandwidthLimiter.slice)
                let wait = delay(for: piece)
                if wait > 0 { try await limiter.sleep(wait) }
                remaining -= piece
            }
        }
    }
}

/// One job's lanes into the buckets of its queue, visible to the providers only while that job runs.
///
/// Providers are shared with previews, the Finder extension and the explorer, none of which should be held back by
/// a limit set for the queue. A task-local reaches exactly the code a job awaits — including the unstructured tasks
/// FTP and SFTP use to serialise their sessions, which inherit it — and nothing else.
struct TransferThrottle: Sendable {
    let upload: BandwidthLimiter.Lane
    let download: BandwidthLimiter.Lane

    init(upload: BandwidthLimiter, download: BandwidthLimiter) {
        self.upload = BandwidthLimiter.Lane(upload)
        self.download = BandwidthLimiter.Lane(download)
    }

    @TaskLocal static var active: TransferThrottle?

    /// Call where an upload has just read a block from disk and is about to send it.
    static func upload(_ bytes: Int) async throws {
        if let lane = active?.upload, lane.isLimited { try await lane.acquire(bytes) }
    }
    /// Call where a download is about to write a block it received.
    static func download(_ bytes: Int) async throws {
        if let lane = active?.download, lane.isLimited { try await lane.acquire(bytes) }
    }
}

/// Holds a URLSession task back while its bucket is in debt, for the bodies URLSession streams by itself (a WebDAV
/// PUT from a file, a download to a temporary file) where there is no read or write of ours to wait in.
///
/// Suspending the task stops it reading from or writing to the socket, so TCP slows the other end down; the bytes
/// counted while it was suspended are already in the debt the next resume waits for.
final class TaskThrottle: @unchecked Sendable {
    private let lane: BandwidthLimiter.Lane
    private let lock = NSLock()
    private var suspended = false

    /// nil when there is nothing to limit, so delegates can keep an optional and skip the work entirely.
    init?(_ lane: BandwidthLimiter.Lane?) {
        guard let lane, lane.isLimited else { return nil }
        self.lane = lane
    }
    func pass(_ bytes: Int64, of task: URLSessionTask) {
        let wait = lane.delay(for: Int(clamping: bytes))
        guard wait > 0 else { return }
        let first = lock.withLock { () -> Bool in
            guard !suspended else { return false }
            suspended = true
            return true
        }
        guard first else { return }
        task.suspend()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { [weak self] in
            if let self { self.lock.withLock { self.suspended = false } }
            // Resuming a task that was cancelled meanwhile is harmless; leaving one suspended would hang it.
            task.resume()
        }
    }
}
