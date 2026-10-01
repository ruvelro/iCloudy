import XCTest
@testable import iCloudy

/// A clock that only moves when somebody sleeps on it, so a rate can be measured exactly and instantly.
private final class FakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 1000
    private(set) var slept: [TimeInterval] = []
    var now: TimeInterval { lock.withLock { time } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds; slept.append(seconds) } }
    func limiter() -> BandwidthLimiter {
        BandwidthLimiter(clock: { [unowned self] in self.now }, sleep: { [unowned self] in self.advance($0) })
    }
}

@MainActor
final class TransferSchedulerTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(latency: Int = 1) throws -> (DemoStore, TransferQueue) {
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(latency)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        return (demo, queue)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<1000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for queue")
        throw CloudError.message("Test timeout")
    }
    private func file(_ name: String, size: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: 7, count: size).write(to: url)
        return url
    }
    private func upload(_ url: URL, account: String = Account.demo.id) -> Transfer {
        Transfer(name: url.lastPathComponent, destination: "Demo", accountID: account, direction: .upload, localURL: url)
    }
    private func queued(_ account: String, target: String? = nil) -> Transfer {
        var job = Transfer(name: account, destination: "", accountID: account, direction: target == nil ? .upload : .transfer,
                           localURL: URL(fileURLWithPath: "/tmp/x"))
        job.targetAccountID = target
        return job
    }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: hour, minute: minute))!
    }

    // MARK: - Limits

    func testStartableHonoursTheGlobalAndPerAccountLimits() {
        let clouds: [String: Cloud] = ["a": .google, "b": .ftp, "c": .dropbox, "m": .mega]
        let items = ["a", "a", "a", "b", "b", "c"].map { queued($0) }
        var policy = TransferPolicy()
        let picked = TransferScheduler.startable(items, running: [], policy: policy, cloud: { clouds[$0] })
        XCTAssertEqual(picked, [items[0].id, items[1].id, items[3].id],
                       "Three at once; the third job of «a» waits for its account, FTP takes one")
        policy.maxConcurrent = 8
        XCTAssertEqual(TransferScheduler.startable(items, running: [], policy: policy, cloud: { clouds[$0] }),
                       [items[0].id, items[1].id, items[3].id, items[5].id], "FTP's second job waits for the first")
        XCTAssertEqual(TransferScheduler.startable(items, running: [items[0].id, items[3].id], policy: policy, cloud: { clouds[$0] }),
                       [items[1].id, items[5].id], "Running jobs count against their accounts")
        policy.maxPerAccount = 4
        XCTAssertEqual(TransferScheduler.perAccountLimit(for: .google, policy: policy), 4)
        for cloud in [Cloud.ftp, .sftp, .mega, .o2] {
            XCTAssertEqual(TransferScheduler.perAccountLimit(for: cloud, policy: policy), 1, "\(cloud) serialises its session")
        }
        policy.maxPerAccount = 1
        XCTAssertEqual(TransferScheduler.perAccountLimit(for: .google, policy: policy), 1)
    }

    func testACrossCloudTransferOccupiesBothAccounts() {
        let clouds: [String: Cloud] = ["a": .google, "m": .mega]
        let copy = queued("a", target: "m"), upload = queued("m"), other = queued("a")
        let picked = TransferScheduler.startable([copy, upload, other], running: [], policy: TransferPolicy(), cloud: { clouds[$0] })
        XCTAssertEqual(picked, [copy.id, other.id], "Mega's only slot is taken by the copy into it")
    }

    func testPriorityDecidesWhichWaitingJobStartsFirst() throws {
        let (_, queue) = try fixture()
        queue.setOnline(false)
        let jobs = try ["a", "b", "c", "d"].map { upload(try file($0, size: 10)) }
        try queue.add(jobs)
        queue.prioritize(jobs[3].id)
        XCTAssertEqual(queue.items.map(\.name), ["d", "a", "b", "c"])
        queue.deprioritize(jobs[0].id)
        XCTAssertEqual(queue.items.map(\.name), ["d", "b", "c", "a"])
        queue.deprioritize(jobs[0].id)
        XCTAssertEqual(queue.items.map(\.name), ["d", "b", "c", "a"], "Already last")
        var policy = TransferPolicy(); policy.maxConcurrent = 2
        XCTAssertEqual(TransferScheduler.startable(queue.items, running: [], policy: policy, cloud: { _ in .google }),
                       [jobs[3].id, jobs[1].id], "The two at the top go first")
        XCTAssertEqual(TransferQueue(storeURL: queue.storeURL).items.map(\.name), ["d", "b", "c", "a"], "Order is persisted")
    }

    func testTheQueueRunsSeveralJobsWithinItsLimits() async throws {
        let (demo, queue) = try fixture(latency: 15)
        queue.cloud = { $0 == "demo:ftp" ? .ftp : .google }
        var policy = TransferPolicy(); policy.maxConcurrent = 3; policy.maxPerAccount = 2
        queue.policy = policy
        var jobs: [Transfer] = []
        for (index, account) in ["demo:a", "demo:a", "demo:a", "demo:ftp", "demo:ftp", "demo:b"].enumerated() {
            jobs.append(upload(try file("f\(index).dat", size: 768 * 1024), account: account))
        }
        let account = Dictionary(uniqueKeysWithValues: jobs.map { ($0.id, $0.accountID) })
        try queue.add(jobs)
        var peak = 0, peakPerAccount: [String: Int] = [:]
        for _ in 0..<2000 where queue.isWorking {
            let running = queue.runningIDs
            peak = max(peak, running.count)
            for (key, value) in Dictionary(grouping: running, by: { account[$0]! }) { peakPerAccount[key] = max(peakPerAccount[key] ?? 0, value.count) }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertFalse(queue.isWorking)
        XCTAssertEqual(peak, 3, "Three jobs ran at once, never more")
        XCTAssertLessThanOrEqual(peakPerAccount["demo:a"] ?? 0, 2)
        XCTAssertEqual(peakPerAccount["demo:ftp"], 1, "FTP's single control connection is never shared")
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .completed })
        XCTAssertEqual(Set(try demo.list("root").map(\.name)).intersection(jobs.map(\.name)).count, jobs.count)
    }

    func testJobsSideBySideNeverPickTheSameName() async throws {
        let (demo, queue) = try fixture(latency: 10)
        let first = root.appendingPathComponent("one"), second = root.appendingPathComponent("two")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let a = first.appendingPathComponent("dup.txt"), b = second.appendingPathComponent("dup.txt")
        try Data(repeating: 1, count: 600 * 1024).write(to: a); try Data(repeating: 2, count: 600 * 1024).write(to: b)
        try queue.add([upload(a), upload(b)])
        try await wait { queue.conflict != nil }
        XCTAssertEqual(queue.conflict?.canReplace, false, "The other job's file is not there yet, so it cannot be replaced")
        queue.resolve(.copy, applyToBatch: false)
        try await wait { !queue.isWorking }
        XCTAssertEqual(Set(try demo.list("root").map(\.name)).intersection(["dup.txt", "dup (2).txt"]).count, 2)
    }

    func testConflictsOfParallelJobsWaitInLineAndBatchAnswersReachThem() async throws {
        let (demo, queue) = try fixture()
        _ = try demo.add(name: "same.txt", parent: "root", content: Data("old".utf8))
        var jobs: [Transfer] = []
        let batch = UUID()
        for folder in ["x", "y", "z"] {
            let dir = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("same.txt"); try Data(folder.utf8).write(to: url)
            var job = upload(url); job.batchID = batch; jobs.append(job)
        }
        var policy = TransferPolicy(); policy.maxConcurrent = 3; policy.maxPerAccount = 3
        queue.policy = policy
        try queue.add(jobs)
        try await wait { queue.conflict != nil && queue.items.filter { $0.state == .running }.count == 3 }
        queue.resolve(.copy, applyToBatch: true)
        try await wait { !queue.isWorking }
        XCTAssertNil(queue.conflict)
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .completed })
        let names = Set(try demo.list("root").map(\.name))
        XCTAssertTrue(names.isSuperset(of: ["same.txt", "same (2).txt", "same (3).txt", "same (4).txt"]))
    }

    // MARK: - Network, schedule and relaunch

    func testLosingTheNetworkPausesEveryRunningJobAndItsReturnResumesThem() async throws {
        let (demo, queue) = try fixture(latency: 20)
        var policy = TransferPolicy(); policy.maxConcurrent = 3; policy.maxPerAccount = 3
        queue.policy = policy
        let jobs = try (0..<3).map { upload(try file("n\($0).dat", size: 2 * 1024 * 1024)) }
        try queue.add(jobs)
        try await wait { queue.items.filter { $0.state == .running && $0.bytes > 0 }.count == 3 }
        queue.setOnline(false)
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.hold, .offline)
        XCTAssertTrue(queue.items.allSatisfy { $0.state == .paused && $0.hold == .offline })
        XCTAssertTrue(queue.items.allSatisfy { $0.status.contains("Sin conexión") })
        queue.setOnline(true)
        XCTAssertNil(queue.hold)
        try await wait { queue.items.allSatisfy { $0.state == .completed } }
        for job in jobs { XCTAssertEqual(try demo.list("root").filter { $0.name == job.name }.count, 1) }
    }

    func testARelaunchRecoversSeveralRunningJobsPausedAndTheyFinishOnce() async throws {
        let (demo, queue) = try fixture(latency: 20)
        var policy = TransferPolicy(); policy.maxConcurrent = 3; policy.maxPerAccount = 3
        queue.policy = policy
        let jobs = try (0..<3).map { upload(try file("r\($0).dat", size: 2 * 1024 * 1024)) }
        try queue.add(jobs)
        try await wait { queue.items.filter { $0.state == .running && ($0.uploads["."]?.offset ?? 0) > 0 }.count == 3 }
        queue.flush()
        // What a crash leaves on disk: three jobs marked as running.
        let restored = TransferQueue(storeURL: queue.storeURL)
        queue.pauseAll(); try await wait { !queue.isWorking }
        restored.client = { _ in CloudAPI(account: .demo, demo: demo) }
        restored.policy = policy
        XCTAssertTrue(restored.items.allSatisfy { $0.state == .paused && $0.hold == nil }, "Back paused, for the person to decide")
        XCTAssertFalse(restored.isWorking)
        XCTAssertEqual(restored.resumeAll(), 3)
        try await wait { !restored.isWorking }
        XCTAssertTrue(restored.items.allSatisfy { $0.state == .completed })
        for job in jobs { XCTAssertEqual(try demo.list("root").filter { $0.name == job.name }.count, 1) }
    }

    func testTheScheduleHoldsJobsOutsideItsWindowAndReleasesThem() async throws {
        let (_, queue) = try fixture(latency: 20)
        var clock = at(12)
        queue.now = { clock }
        var policy = TransferPolicy(); policy.window = TransferWindow(start: 22 * 60, end: 7 * 60)
        queue.policy = policy
        XCTAssertEqual(queue.hold, .schedule)
        let job = upload(try file("night.dat", size: 2 * 1024 * 1024))
        try queue.add([job])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(queue.isWorking, "Nothing starts at noon")
        XCTAssertEqual(queue.items.first?.state, .queued)

        clock = at(23, 30); queue.reevaluate()
        XCTAssertNil(queue.hold)
        try await wait { (queue.items.first?.bytes ?? 0) > 0 }
        clock = at(7, 1); queue.reevaluate()
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.items.first?.state, .paused)
        XCTAssertEqual(queue.items.first?.hold, .schedule)
        XCTAssertTrue(queue.items.first?.status.contains("22:00") == true, queue.items.first?.status ?? "")

        // A hold survives a relaunch, unlike a pause for lack of network.
        let restored = TransferQueue(storeURL: queue.storeURL)
        XCTAssertEqual(restored.items.first?.hold, .schedule)

        clock = at(22); queue.reevaluate()
        try await wait { queue.items.first?.state == .completed }
    }

    func testACostlyNetworkPausesOnlyWhenThePolicyAsks() async throws {
        let (_, queue) = try fixture(latency: 20)
        queue.setCostlyNetwork(true)
        XCTAssertNil(queue.hold, "Off by default")
        let job = upload(try file("phone.dat", size: 2 * 1024 * 1024))
        try queue.add([job])
        try await wait { (queue.items.first?.bytes ?? 0) > 0 }
        var policy = TransferPolicy(); policy.pauseOnCostlyNetwork = true
        queue.policy = policy
        try await wait { !queue.isWorking }
        XCTAssertEqual(queue.hold, .costlyNetwork)
        XCTAssertEqual(queue.items.first?.hold, .costlyNetwork)
        // Losing the network on top relabels the job; getting it back still leaves it waiting for the cheap one.
        queue.setOnline(false)
        XCTAssertEqual(queue.items.first?.hold, .offline)
        queue.setOnline(true)
        XCTAssertEqual(queue.items.first?.hold, .costlyNetwork)
        queue.setCostlyNetwork(false)
        try await wait { queue.items.first?.state == .completed }
    }

    func testAJobPausedByHandIsNotResumedWhenAHoldLifts() async throws {
        let (_, queue) = try fixture()
        queue.setOnline(false)
        let manual = upload(try file("manual.dat", size: 10)), automatic = upload(try file("auto.dat", size: 10))
        try queue.add([manual, automatic])
        queue.cancel(manual.id, pause: true)
        queue.setOnline(true)
        try await wait { !queue.isWorking && queue.items.last?.state == .completed }
        XCTAssertEqual(queue.items.first?.state, .paused)
    }

    // MARK: - Schedule window

    func testTheWindowCrossesMidnightAndKnowsItsNextEdge() {
        let night = TransferWindow(start: 22 * 60, end: 7 * 60)
        XCTAssertTrue(night.contains(at(23)))
        XCTAssertTrue(night.contains(at(0, 30)))
        XCTAssertTrue(night.contains(at(6, 59)))
        XCTAssertFalse(night.contains(at(7)))
        XCTAssertFalse(night.contains(at(12)))
        XCTAssertTrue(night.contains(at(22)))
        XCTAssertEqual(night.nextChange(after: at(12)), at(22))
        XCTAssertEqual(night.nextChange(after: at(23)), Calendar.current.date(byAdding: .day, value: 1, to: at(7)))
        XCTAssertEqual(night.nextChange(after: at(3)), at(7))

        let office = TransferWindow(start: 9 * 60, end: 17 * 60 + 30)
        XCTAssertTrue(office.contains(at(9)))
        XCTAssertTrue(office.contains(at(17, 29)))
        XCTAssertFalse(office.contains(at(17, 30)))
        XCTAssertFalse(office.contains(at(8, 59)))
        XCTAssertEqual(office.nextChange(after: at(10)), at(17, 30))

        let always = TransferWindow(start: 600, end: 600)
        XCTAssertTrue(always.contains(at(3)), "Equal ends never freeze the queue")
        XCTAssertNil(always.nextChange(after: at(3)))
        XCTAssertEqual(TransferWindow.text(7 * 60 + 5), "07:05")
    }

    func testThePolicyIsReadFromTheSettings() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "transfer-policy-" + UUID().uuidString))
        XCTAssertEqual(TransferPolicy.stored(in: defaults), TransferPolicy(), "No settings, the defaults")
        defaults.set(5, forKey: Prefs.transferConcurrency)
        defaults.set(99, forKey: Prefs.transferPerAccount)
        defaults.set(true, forKey: Prefs.uploadLimitEnabled); defaults.set(512, forKey: Prefs.uploadLimitValue); defaults.set("KB", forKey: Prefs.uploadLimitUnit)
        defaults.set(false, forKey: Prefs.downloadLimitEnabled); defaults.set(3, forKey: Prefs.downloadLimitValue)
        defaults.set(true, forKey: Prefs.transferWindowEnabled); defaults.set(0, forKey: Prefs.transferWindowStart); defaults.set(360, forKey: Prefs.transferWindowEnd)
        defaults.set(true, forKey: Prefs.pauseOnCostlyNetwork)
        let policy = TransferPolicy.stored(in: defaults)
        XCTAssertEqual(policy.maxConcurrent, 5)
        XCTAssertEqual(policy.maxPerAccount, TransferPolicy.perAccountRange.upperBound, "Clamped")
        XCTAssertEqual(policy.uploadLimit, 512_000)
        XCTAssertNil(policy.downloadLimit, "Switched off keeps its value but limits nothing")
        XCTAssertEqual(policy.window, TransferWindow(start: 0, end: 360), "Midnight is a valid start")
        XCTAssertTrue(policy.pauseOnCostlyNetwork)
    }

    // MARK: - Persistence

    func testTheHoldRoundTripsAndOldQueuesStillDecode() throws {
        var job = Transfer(name: "a", destination: "d", accountID: "acc", direction: .upload, localURL: URL(fileURLWithPath: "/tmp/a"))
        job.state = .paused; job.hold = .schedule
        let decoded = try JSONDecoder().decode(Transfer.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(decoded.hold, .schedule)

        let old = Data(#"[{"id":"\#(UUID().uuidString)","name":"viejo","accountID":"acc","direction":"upload","localURL":"file:///tmp/viejo","state":"paused","detail":"Sin conexión"}]"#.utf8)
        let legacy = try JSONDecoder().decode([Transfer].self, from: old)
        XCTAssertNil(legacy.first?.hold, "A queue written before holds existed reads as paused by hand")

        let future = Data(#"[{"name":"nuevo","accountID":"acc","direction":"upload","localURL":"file:///tmp/n","state":"paused","hold":"solar-eclipse"}]"#.utf8)
        XCTAssertNil(try JSONDecoder().decode([Transfer].self, from: future).first?.hold, "An unknown reason is no reason")

        // On disk: a schedule hold survives a relaunch; an offline one becomes an ordinary pause, as it always was.
        var offline = job; offline.id = UUID(); offline.hold = .offline; offline.detail = "Sin conexión"
        var running = job; running.id = UUID(); running.state = .running; running.hold = nil
        let url = root.appendingPathComponent("queue.json")
        try LocalStore.save([job, offline, running], to: url)
        let restored = TransferQueue(storeURL: url)
        XCTAssertEqual(restored.items.map(\.hold), [.schedule, nil, nil])
        XCTAssertEqual(restored.items[1].detail, "")
        XCTAssertEqual(restored.items[2].state, .paused)
        restored.setOnline(false)
        XCTAssertEqual(restored.items[0].hold, .offline, "Relabelled while the network is away")
        XCTAssertNil(restored.items[1].hold, "A pause by hand is never taken over")
    }

    // MARK: - Bandwidth

    func testTheBucketHoldsItsRate() async throws {
        let clock = FakeClock()
        let limiter = clock.limiter(), lane = BandwidthLimiter.Lane(limiter)
        try await lane.acquire(5_000_000)
        XCTAssertTrue(clock.slept.isEmpty, "No limit, no waiting")
        limiter.bytesPerSecond = 100_000
        // Whole slices, so the measurement is not blurred by the change a lane keeps for its next call.
        let amount = 16 * BandwidthLimiter.slice
        let start = clock.now
        try await lane.acquire(amount)
        // The first slice goes out of the initial burst; the rest at the limit.
        let expected = Double(amount - BandwidthLimiter.slice) / 100_000
        XCTAssertEqual(clock.now - start, expected, accuracy: expected * 0.02, "Within 2 % of the limit, after the initial burst")
        // A quiet spell refills the burst, never more.
        clock.advance(60)
        let again = clock.now
        try await lane.acquire(amount)
        XCTAssertEqual(clock.now - again, expected, accuracy: expected * 0.02)
        limiter.bytesPerSecond = 0
        XCTAssertFalse(limiter.isLimited)
        XCTAssertEqual(lane.delay(for: 10_000_000), 0)
    }

    func testConcurrentJobsShareTheLimitFairly() {
        // Two jobs, one sending 5 MiB blocks a slice at a time and one writing 16 KiB pieces, each waking when its
        // last turn has been paid for.
        let clock = FakeClock()
        let limiter = clock.limiter()
        limiter.bytesPerSecond = 1_000_000
        let lanes = [BandwidthLimiter.Lane(limiter), BandwidthLimiter.Lane(limiter)]
        let total = 4_000_000
        var sent = [0, 0], wake = [clock.now, clock.now], done: [TimeInterval?] = [nil, nil]
        let sizes = [BandwidthLimiter.slice, 16 * 1024]
        var halfway: [Int]?
        while done.contains(where: { $0 == nil }) {
            let who = (0..<2).filter { done[$0] == nil }.min { wake[$0] < wake[$1] }!
            if wake[who] > clock.now { clock.advance(wake[who] - clock.now) }
            let piece = min(sizes[who], total - sent[who])
            wake[who] = clock.now + lanes[who].delay(for: piece)
            sent[who] += piece
            if sent[who] == total { done[who] = wake[who] }
            if halfway == nil, sent.reduce(0, +) >= total { halfway = sent }
        }
        let share = Double(halfway![0]) / Double(halfway![0] + halfway![1])
        XCTAssertEqual(share, 0.5, accuracy: 0.05, "Each job had half of the limit while both were moving")
        let elapsed = max(done[0]!, done[1]!) - 1000
        // The bucket starts with a quarter of a second of the limit.
        let expected = Double(2 * total - 250_000) / 1_000_000
        XCTAssertEqual(elapsed, expected, accuracy: expected * 0.02, "Together they never exceeded it")
    }

    func testThrottleOnlyExistsInsideAQueueJob() async throws {
        XCTAssertNil(TransferThrottle.active, "Previews and the explorer are never limited")
        let clock = FakeClock()
        let upload = clock.limiter()
        upload.bytesPerSecond = 1000
        let throttle = TransferThrottle(upload: upload, download: clock.limiter())
        try await TransferThrottle.upload(1_000_000)
        XCTAssertTrue(clock.slept.isEmpty)
        try await TransferThrottle.$active.withValue(throttle) {
            try await TransferThrottle.download(1_000_000)
            XCTAssertTrue(clock.slept.isEmpty, "The download bucket has no limit")
            try await TransferThrottle.upload(200_000)
        }
        XCTAssertFalse(clock.slept.isEmpty)
        XCTAssertNil(TaskThrottle(nil))
        XCTAssertNil(TaskThrottle(throttle.download), "An unlimited bucket needs no suspending")
        XCTAssertNotNil(TaskThrottle(throttle.upload))
    }

    func testTheQueueHandsItsPolicyToItsBuckets() throws {
        let (_, queue) = try fixture()
        var policy = TransferPolicy(); policy.uploadLimit = 250_000
        queue.policy = policy
        XCTAssertEqual(queue.uploadLimiter.bytesPerSecond, 250_000)
        XCTAssertNil(queue.downloadLimiter.bytesPerSecond)
        queue.policy = TransferPolicy()
        XCTAssertNil(queue.uploadLimiter.bytesPerSecond)
    }

    func testActivityAddsUpEveryRunningJob() {
        var a = queued("a"); a.state = .running; a.bytes = 100; a.total = 400; a.bytesPerSecond = 1000
        var b = queued("b"); b.state = .running; b.bytes = 300; b.total = 400; b.bytesPerSecond = 500
        var c = queued("c"); c.state = .paused
        let d = queued("d")
        var e = queued("e"); e.state = .failed
        let activity = TransferActivity([a, b, c, d, e])
        XCTAssertEqual(activity.running, 2); XCTAssertEqual(activity.waiting, 1)
        XCTAssertEqual(activity.paused, 1); XCTAssertEqual(activity.failed, 1)
        XCTAssertEqual(activity.progress, 0.5)
        XCTAssertEqual(activity.bytesPerSecond, 1500)
        XCTAssertNotNil(activity.speed)
        XCTAssertNil(TransferActivity([d]).speed)
    }
}
