import XCTest
@testable import iCloudy

/// The data behind the panel's charts: the recent speed and the bytes moved per day.
@MainActor
final class TransferStatisticsTests: XCTestCase {
    func testTheSpeedHistoryKeepsTheLastTwoMinutes() {
        let history = SpeedHistory()
        for i in 0..<(SpeedHistory.limit + 30) { history.record(Double(i), at: Date(timeIntervalSince1970: Double(i))) }
        XCTAssertEqual(history.samples.count, SpeedHistory.limit)
        XCTAssertEqual(history.samples.first?.bytesPerSecond, 30)
        XCTAssertEqual(history.peak, Double(SpeedHistory.limit + 29))
        history.record(-5)
        XCTAssertEqual(history.samples.last?.bytesPerSecond, 0, "Never below zero")
    }

    func testBytesAreAddedUpPerDayWithEmptyDaysAtZero() throws {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 6, hour: 12)))
        func entry(_ daysAgo: Int, _ bytes: Int64) -> HistoryEntry {
            var transfer = Transfer(name: "x", destination: "d", accountID: "a", direction: .upload, localURL: URL(fileURLWithPath: "/x"))
            transfer.bytes = bytes
            return HistoryEntry(transfer: transfer, finishedAt: now.addingTimeInterval(Double(-daysAgo) * 86_400))
        }
        let days = TransferHistory.bytesPerDay([entry(0, 10), entry(0, 5), entry(2, 7), entry(30, 99)], days: 7, now: now, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.bytes, 15, "Today")
        XCTAssertEqual(days[days.count - 3].bytes, 7)
        XCTAssertEqual(days.reduce(0) { $0 + $1.bytes }, 22, "Older than the window is left out")
        XCTAssertEqual(days.first?.day, calendar.startOfDay(for: now.addingTimeInterval(-6 * 86_400)))
    }

    func testTheQueueSamplesWhileItRunsAndEndsAtZero() async throws {
        let root = try temporaryRoot()
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(2)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.speedSampleInterval = .milliseconds(5)
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let file = root.appendingPathComponent("grande.bin")
        try Data(repeating: 1, count: 3 * 256 * 1024).write(to: file)
        try queue.add([Transfer(name: "grande.bin", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: file)])
        try await wait { queue.items.first?.state == .completed && queue.samplingTask == nil }
        XCTAssertGreaterThan(queue.speed.samples.count, 1)
        XCTAssertEqual(queue.speed.samples.last?.bytesPerSecond, 0)
    }
}
