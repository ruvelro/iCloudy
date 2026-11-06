import XCTest
@testable import iCloudy

/// Schedules of their own for mirrors, on top of the queue's window and holds.
@MainActor
final class MirrorScheduleTests: XCTestCase {
    private var utc: Calendar { var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!; return calendar }
    private func at(_ hour: Int, _ minute: Int, day: Int = 10) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    func testWhenEachScheduleFallsDue() {
        let every = SyncSchedule.every(3600)
        XCTAssertEqual(every.nextRun(after: nil, now: at(9, 0)), at(9, 0), "Never run: due now")
        XCTAssertEqual(every.nextRun(after: at(8, 30), now: at(9, 0)), at(9, 30))
        XCTAssertEqual(SyncSchedule.every(1).nextRun(after: at(9, 0), now: at(9, 0)), at(9, 1), "Never more often than a minute")
        let daily = SyncSchedule.daily(3 * 60)
        XCTAssertEqual(daily.nextRun(after: at(2, 0), now: at(9, 0), calendar: utc), at(3, 0), "Missed this morning: due at once")
        XCTAssertEqual(daily.nextRun(after: at(3, 5), now: at(9, 0), calendar: utc), at(3, 0, day: 11), "Done today: tomorrow")
        XCTAssertEqual(daily.nextRun(after: at(3, 0, day: 5), now: at(9, 0), calendar: utc), at(3, 0), "Missed for days: once, now")
        XCTAssertEqual(daily.nextRun(after: at(3, 5, day: 9), now: at(2, 0), calendar: utc), at(3, 0), "Done yesterday: next is today's")
    }

    private func fixture(_ options: MirrorOptions) async throws -> (MirrorManager, TransferQueue, URL) {
        let root = try temporaryRoot()
        let local = root.appendingPathComponent("Carpeta")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("a".utf8).write(to: local.appendingPathComponent("a.txt"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let folder = try demo.add(name: "Destino", parent: "root", folder: true)
        try manager.add(local: local, account: .demo, folder: try XCTUnwrap(demo.list("root").first { $0.id == folder }), path: [])
        manager.setOptions(options, for: manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != nil && manager.mirrors.first?.activeTransferID == nil }
        return (manager, queue, local)
    }

    func testAScheduledRunPicksUpWhatNoEventAnnounced() async throws {
        let (manager, queue, local) = try await fixture(MirrorOptions(schedule: .every(3600)))
        let synced = try XCTUnwrap(manager.mirrors[0].lastSync)
        try Data("nuevo".utf8).write(to: local.appendingPathComponent("b.txt"))
        let jobs = queue.items.count
        manager.tick(now: synced.addingTimeInterval(600))
        try await assertStays({ queue.items.count == jobs }, for: .milliseconds(80), "Not due yet")
        XCTAssertEqual(manager.nextScheduled(now: synced), synced.addingTimeInterval(3600))
        manager.tick(now: synced.addingTimeInterval(3700))
        try await wait { queue.items.count == jobs + 1 && manager.mirrors[0].activeTransferID == nil }
        XCTAssertEqual(manager.mirrors[0].lastScheduledRun, synced.addingTimeInterval(3700))
        XCTAssertTrue(manager.mirrors[0].stamps.keys.contains("b.txt"))
    }

    func testARunDueWhileTheQueueIsHeldWaitsForTheHoldToLift() async throws {
        let (manager, queue, _) = try await fixture(MirrorOptions(schedule: .every(3600)))
        manager.startSchedules()
        manager.mirrors[0].lastSync = Date(timeIntervalSinceNow: -7200)
        queue.setOnline(false)
        manager.tick()
        XCTAssertNil(manager.mirrors[0].lastScheduledRun, "Offline: nothing starts")
        queue.setOnline(true)
        try await wait { manager.mirrors[0].lastScheduledRun != nil }
    }

    func testAScheduledVerificationRunsWhenDue() async throws {
        let (manager, queue, _) = try await fixture(MirrorOptions(verifyEvery: 86_400))
        XCTAssertNil(manager.mirrors[0].lastVerified)
        manager.tick(now: Date())
        try await wait { manager.mirrors[0].lastVerified != nil }
        XCTAssertNotNil(manager.mirrors[0].lastVerification)
        manager.mirrors[0].paused = true
        XCTAssertNil(manager.nextScheduled(), "A paused mirror has nothing scheduled")
        withExtendedLifetime(queue) {}
    }

    func testOlderRecordsHaveNoScheduleAndUnknownKindsAreIgnored() throws {
        XCTAssertNil(try JSONDecoder().decode(MirrorOptions.self, from: Data("{}".utf8)).schedule)
        let future = try JSONDecoder().decode(MirrorOptions.self, from: Data(#"{"schedule":{"weekly":{"_0":3}},"exact":true}"#.utf8))
        XCTAssertNil(future.schedule)
        XCTAssertTrue(future.exact, "The rest of the settings survive")
        let saved = try JSONDecoder().decode(MirrorOptions.self, from: JSONEncoder().encode(MirrorOptions(schedule: .daily(90))))
        XCTAssertEqual(saved.schedule, .daily(90))
        XCTAssertNil(try JSONDecoder().decode(FolderMirror.self, from: Data(#"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/"}"#.utf8)).lastScheduledRun)
    }
}
