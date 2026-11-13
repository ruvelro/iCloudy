import XCTest
@testable import iCloudy

/// A clock that moves only when someone sleeps on it, so rates are measured exactly and at once.
private final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func limiter(_ rate: Int64?) -> BandwidthLimiter {
        let limiter = BandwidthLimiter(clock: { [unowned self] in self.now }, sleep: { [unowned self] in self.advance($0) })
        limiter.bytesPerSecond = rate
        return limiter
    }
}

/// Per-account bandwidth limits, on top of the queue's own.
@MainActor
final class AccountBandwidthTests: XCTestCase {
    func testALaneThroughTwoBucketsGoesAtTheSlowerOne() async throws {
        let clock = ManualClock()
        let queueWide = clock.limiter(nil), account = clock.limiter(200_000)
        let lane = BandwidthLimiter.Lane([queueWide, account])
        XCTAssertTrue(lane.isLimited, "Limited by the account alone")
        let start = clock.now
        try await lane.acquire(2_000_000)
        let elapsed = clock.now - start
        XCTAssertEqual(2_000_000 / elapsed, 200_000, accuracy: 30_000, "The account's rate")

        let fast = clock.limiter(1_000_000), slow = clock.limiter(100_000)
        let both = BandwidthLimiter.Lane([fast, slow])
        let again = clock.now
        try await both.acquire(1_000_000)
        XCTAssertEqual(1_000_000 / (clock.now - again), 100_000, accuracy: 20_000, "The stricter of the two")
        XCTAssertFalse(BandwidthLimiter.Lane([clock.limiter(nil), clock.limiter(nil)]).isLimited)
    }

    func testTheQueueGivesEachAccountItsOwnBuckets() {
        let queue = TransferQueue(storeURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        var policy = TransferPolicy()
        policy.accountLimits = ["lenta": AccountBandwidth(upload: 100_000, download: nil)]
        queue.policy = policy
        XCTAssertTrue(queue.throttle(upload: "lenta", download: nil).upload.isLimited)
        XCTAssertFalse(queue.throttle(upload: nil, download: "lenta").download.isLimited, "Only the direction that has a limit")
        XCTAssertFalse(queue.throttle(upload: "otra", download: "otra").upload.isLimited)
        let running = queue.throttle(upload: "lenta", download: nil)
        queue.policy = TransferPolicy()
        XCTAssertFalse(running.upload.isLimited, "Lifting the limit frees the lanes already handed out")
    }

    func testLimitsAreStoredClampedAndReadLeniently() {
        AccountBandwidth.store(["a": AccountBandwidth(upload: 5, download: nil), "b": AccountBandwidth()])
        XCTAssertEqual(AccountBandwidth.stored(), ["a": AccountBandwidth(upload: TransferPolicy.minimumLimit, download: nil)],
                       "Raised to the minimum; an empty entry is dropped")
        XCTAssertEqual(TransferPolicy.stored().accountLimits.count, 1)
        Prefs.defaults.set(Data("no es json".utf8), forKey: Prefs.accountBandwidthLimits)
        XCTAssertTrue(AccountBandwidth.stored().isEmpty)
        AccountBandwidth.store([:])
        XCTAssertNil(Prefs.defaults.object(forKey: Prefs.accountBandwidthLimits))
        let old = try? JSONDecoder().decode(AccountBandwidth.self, from: Data("{}".utf8))
        XCTAssertEqual(old?.isEmpty, true)
    }
}
