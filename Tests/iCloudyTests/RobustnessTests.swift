import XCTest
@testable import iCloudy

/// Writes off the main thread, a queue file that stops growing, and large answers parsed in the background.
@MainActor
final class RobustnessTests: XCTestCase {
    private func temporaryURL() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json") }

    func testTheNewestWriteOfAFileWinsAndAnImmediateOneWaitsItsTurn() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = StoreWriter()
        for value in 0..<200 { writer.later([value], to: url) }
        writer.flush()
        XCTAssertEqual(try LocalStore.read([Int].self, from: url), [199], "Una ráfaga acaba en el último valor")

        writer.later(["antes"], to: url)
        try writer.now(["ahora"], to: url)
        writer.flush()
        XCTAssertEqual(try LocalStore.read([String].self, from: url), ["ahora"], "Lo inmediato no lo pisa una escritura anterior")
    }

    func testAFailedBackgroundWriteIsReported() async throws {
        let writer = StoreWriter()
        let blocked = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: blocked)
        defer { try? FileManager.default.removeItem(at: blocked) }
        let reported = expectation(description: "error")
        // A file where a folder should be: the directory cannot be created, so the write fails.
        writer.later([1], to: blocked.appendingPathComponent("store.json")) { _ in reported.fulfill() }
        await fulfillment(of: [reported], timeout: 5)
    }

    func testAReadSeesWhatThisProcessWroteEvenIfTheWriteWasStillPending() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        StoreWriter.shared.later(["pendiente"], to: url)
        XCTAssertEqual(try LocalStore.read([String].self, from: url), ["pendiente"])
    }

    func testTheQueueKeepsOnlyTheNewestFinishedJobs() throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let total = TransferQueue.finishedLimit + 40
        var jobs = (0..<total).map { index -> Transfer in
            var job = Transfer(name: "terminada \(index)", destination: "", accountID: "a", direction: .upload, localURL: URL(fileURLWithPath: "/"))
            job.state = index.isMultiple(of: 3) ? .failed : .completed
            return job
        }
        var waiting = Transfer(name: "en pausa", destination: "", accountID: "a", direction: .upload, localURL: URL(fileURLWithPath: "/"))
        waiting.state = .paused
        jobs.insert(waiting, at: 0)
        try LocalStore.save(jobs, to: url)

        let queue = TransferQueue(storeURL: url)
        XCTAssertEqual(queue.items.filter(\.finished).count, TransferQueue.finishedLimit)
        XCTAssertEqual(queue.items.first?.name, "en pausa", "Lo que no ha terminado nunca se recorta")
        XCTAssertEqual(queue.items.last?.name, "terminada \(total - 1)", "Se quedan las más recientes")
        XCTAssertFalse(queue.items.contains { $0.name == "terminada 0" })
    }

    func testLargeAnswersAreParsedInTheBackgroundAndGiveTheSameResult() async throws {
        let entries = (0..<3_000).map { ["id": "\($0)", "name": "archivo \($0).txt"] }
        let data = try JSONSerialization.data(withJSONObject: ["files": entries])
        XCTAssertGreaterThan(data.count, HTTP.backgroundParseThreshold)
        let parsed = try await HTTP.object(data)
        XCTAssertEqual((parsed["files"] as? [[String: String]])?.count, 3_000)
        let small = try await HTTP.object(Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(small["ok"] as? Bool, true)
        let fragment = try await HTTP.parse(Data("-3".utf8), fragments: true)
        XCTAssertEqual(fragment as? Int, -3, "Mega contesta números sueltos")
        do { _ = try await HTTP.object(Data("[1,2]".utf8)); XCTFail("Una lista no es un objeto") } catch {}
    }
}
