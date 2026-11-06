import XCTest
@testable import iCloudy

/// Saved transfer jobs: their store, their runs through the queue and what each run does when it ends.
@MainActor
final class JobsTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let demo: DemoStore
        let queue: TransferQueue
        let store: JobStore
        let folder: String
    }
    private func fixture() throws -> Fixture {
        let root = try temporaryRoot()
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .zero; demo.listsChecksums = true
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let store = JobStore(storeURL: root.appendingPathComponent("jobs.json"))
        store.queue = queue
        store.trashLocally = { try FileManager.default.removeItem(at: $0) }
        store.start()
        let folder = try demo.add(name: "Copias", parent: "root", folder: true)
        return Fixture(root: root, demo: demo, queue: queue, store: store, folder: folder)
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func remote(_ f: Fixture) -> JobEndpoint {
        .remote(accountID: Account.demo.id, itemID: f.folder, name: "Copias", isFolder: true, location: "Demo / Copias")
    }
    private func finished(_ f: Fixture, _ id: UUID) async throws {
        try await wait { f.store.job(id)?.running == false && f.store.job(id)?.lastResult != L("En marcha") }
    }

    func testAJobIsSavedAndReadBackAndAnUnreadableFileIsSetAside() throws {
        let f = try fixture()
        let job = SavedJob(name: "Fotos a Drive", sources: [.local(URL(fileURLWithPath: "/tmp/Fotos"), bookmark: nil)], destination: remote(f),
                           options: JobOptions(conflictPolicy: .newestWins, verifyAfter: true, schedule: .daily(120)))
        try f.store.add(job)
        let again = JobStore(storeURL: f.store.storeURL)
        XCTAssertEqual(again.jobs, [job])
        XCTAssertEqual(again.job(named: "fotos a drive")?.id, job.id, "Found by name, whatever the case")
        XCTAssertThrowsError(try f.store.add(SavedJob(name: "x", sources: [.local(URL(fileURLWithPath: "/a"), bookmark: nil)],
                                                      destination: .local(URL(fileURLWithPath: "/b"), bookmark: nil))))
        try Data("{roto".utf8).write(to: f.store.storeURL)
        let damaged = JobStore(storeURL: f.store.storeURL)
        XCTAssertTrue(damaged.jobs.isEmpty)
        XCTAssertNotNil(damaged.persistenceError)
        let kept = try FileManager.default.contentsOfDirectory(atPath: f.root.path).filter { $0.hasPrefix("jobs.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "The damaged file is kept beside, not overwritten")
    }

    func testJobsWrittenWithFewerFieldsStillRead() throws {
        let json = #"{"schemaVersion":1,"items":[{"id":"8F9C2C51-4A8B-4E2E-9F7A-0D2B6C1E5A11","name":"Viejo","sources":[{"local":{"_0":"file:///tmp/a","bookmark":null}}],"destination":{"remote":{"accountID":"demo:local","itemID":"r","name":"R","isFolder":true,"location":"Demo / R"}}}]}"#
        let decoded = try JSONDecoder().decode(StoreEnvelope<[SavedJob]>.self, from: Data(json.utf8))
        let job = try XCTUnwrap(decoded.items.first)
        XCTAssertEqual(job.name, "Viejo")
        XCTAssertEqual(job.options, JobOptions())
        XCTAssertFalse(job.running)
        XCTAssertEqual(try job.kind(), .upload)
        let future = try JSONDecoder().decode(JobOptions.self, from: Data(#"{"conflictPolicy":"coin","schedule":{"hourly":{}},"verifyAfter":true}"#.utf8))
        XCTAssertNil(future.conflictPolicy); XCTAssertNil(future.schedule); XCTAssertTrue(future.verifyAfter)
    }

    func testARunIsABatchOfTheQueueWithItsReportAndItsVerification() async throws {
        let f = try fixture()
        let folder = f.root.appendingPathComponent("Fotos")
        try write("a", to: folder.appendingPathComponent("a.txt"))
        try write("b", to: folder.appendingPathComponent("sub/b.txt"))
        let file = f.root.appendingPathComponent("suelto.txt"); try write("s", to: file)
        let job = SavedJob(name: "Subida", sources: [.local(folder, bookmark: nil), .local(file, bookmark: nil)], destination: remote(f),
                           options: JobOptions(verifyAfter: true))
        try f.store.add(job)
        let batch = try await f.store.run(job.id)
        try await finished(f, job.id)
        let transfers = f.queue.items.filter { $0.batchID == batch }
        XCTAssertEqual(transfers.count, 2)
        XCTAssertTrue(transfers.allSatisfy { $0.state == .completed })
        XCTAssertEqual(TransferReport(jobs: transfers).copied, 3)
        let result = try XCTUnwrap(f.store.job(job.id)?.lastResult)
        XCTAssertTrue(result.contains("3"), result)
        XCTAssertTrue(result.contains(VerificationSummary(checked: 3).text.components(separatedBy: " ").first ?? "x"), result)
        XCTAssertEqual(f.store.job(job.id)?.lastBatchID, batch)
        XCTAssertEqual(try f.demo.list(f.folder).map(\.name).sorted(), ["Fotos", "suelto.txt"])
    }

    func testRunningAgainUsesThePolicyAndCarriesDeletionsBehindTheBrake() async throws {
        let f = try fixture()
        let folder = f.root.appendingPathComponent("Docs")
        try write("uno", to: folder.appendingPathComponent("a.txt"))
        try write("dos", to: folder.appendingPathComponent("b.txt"))
        let job = SavedJob(name: "Docs", sources: [.local(folder, bookmark: nil)], destination: remote(f),
                           options: JobOptions(conflictPolicy: .thisSideWins, deleteExtraneous: true))
        try f.store.add(job)
        try await f.store.run(job.id)
        try await finished(f, job.id)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b.txt"))
        try write("uno bis", to: folder.appendingPathComponent("a.txt"))
        try await f.store.run(job.id)
        try await finished(f, job.id)
        XCTAssertNil(f.queue.conflict, "Replaced by policy, nobody asked")
        let docs = try XCTUnwrap(f.demo.list(f.folder).first { $0.name == "Docs" })
        XCTAssertEqual(try f.demo.list(docs.id).map(\.name), ["a.txt"], "b.txt went to the trash")
        XCTAssertEqual(try f.demo.list(Collection.trash.rootID).map(\.name), ["b.txt"])

        // Deleting most of the destination stops until a run is allowed to.
        for i in 0..<12 { _ = try f.demo.add(name: "extra\(i).txt", parent: docs.id, content: Data("x".utf8)) }
        try await f.store.run(job.id)
        try await finished(f, job.id)
        XCTAssertEqual(try f.demo.list(docs.id).count, 13)
        XCTAssertTrue(f.store.job(job.id)?.lastResult?.contains("12") == true, f.store.job(job.id)?.lastResult ?? "")
        try await f.store.run(job.id, allowingMassDeletion: true)
        try await finished(f, job.id)
        XCTAssertEqual(try f.demo.list(docs.id).map(\.name), ["a.txt"])
    }

    func testADownloadJobAndAJobRunningTwiceAtOnce() async throws {
        let f = try fixture()
        let source = try f.demo.add(name: "informe.txt", parent: f.folder, content: Data("contenido".utf8))
        let target = f.root.appendingPathComponent("Bajadas")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let job = SavedJob(name: "Bajar", sources: [.remote(accountID: Account.demo.id, itemID: source, name: "informe.txt", isFolder: false, location: "Demo / informe.txt")],
                           destination: .local(target, bookmark: nil), options: JobOptions(verifyAfter: true))
        try f.store.add(job)
        f.queue.pauseAll()
        let batch = try await f.store.run(job.id)
        do { try await f.store.run(job.id); XCTFail("A second run while the first is going") } catch {}
        try await finished(f, job.id)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("informe.txt"), encoding: .utf8), "contenido")
        let transfer = try XCTUnwrap(f.queue.items.first { $0.batchID == batch })
        XCTAssertEqual(transfer.verifiedFiles, 1, "Checked against the checksum fetched at run time")
    }

    func testAScheduledJobRunsWhenDueAndNotWhileRunning() async throws {
        let f = try fixture()
        let file = f.root.appendingPathComponent("x.txt"); try write("x", to: file)
        let job = SavedJob(name: "Cada hora", sources: [.local(file, bookmark: nil)], destination: remote(f), options: JobOptions(schedule: .every(3600)))
        try f.store.add(job)
        let now = Date()
        XCTAssertEqual(f.store.nextScheduled(now: now), now, "Never run: due now")
        f.store.tick(now: now)
        try await wait { f.store.job(job.id)?.lastRun != nil }
        try await finished(f, job.id)
        XCTAssertEqual(f.store.job(job.id)?.lastScheduledRun, now)
        let runs = f.queue.items.count
        f.store.tick(now: now.addingTimeInterval(60))
        try await assertStays({ f.queue.items.count == runs }, for: .milliseconds(80))
        f.queue.setOnline(false)
        f.store.tick(now: now.addingTimeInterval(7200))
        try await assertStays({ f.queue.items.count == runs }, for: .milliseconds(80), "Held: waits")
    }
}
