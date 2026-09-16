import XCTest
@testable import iCloudy

@MainActor
final class MirrorTests: XCTestCase {
    private func tree(_ root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub/deep"), withIntermediateDirectories: true)
        try Data("a".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("b".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
        try Data("c".utf8).write(to: root.appendingPathComponent("sub/deep/c.txt"))
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out"); throw CloudError.message("timeout")
    }

    func testPlannerMarksUnchangedFilesAndFullyUnchangedFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try tree(root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let first = try MirrorPlanner.stamps(of: root)
        XCTAssertEqual(Set(first.keys), ["a.txt", "sub/b.txt", "sub/deep/c.txt"], "Symlinks are skipped")
        let allDone = MirrorPlanner.completedKeys(current: first, previous: first)
        XCTAssertEqual(allDone, ["./a.txt", "./sub/b.txt", "./sub/deep/c.txt", "./sub", "./sub/deep"])
        XCTAssertFalse(allDone.contains("."), "The root always runs")
        XCTAssertTrue(MirrorPlanner.completedKeys(current: first, previous: [:]).isEmpty)
        try Data("bb".utf8).write(to: root.appendingPathComponent("sub/b.txt"))
        let second = try MirrorPlanner.stamps(of: root)
        let partial = MirrorPlanner.completedKeys(current: second, previous: first)
        XCTAssertEqual(partial, ["./a.txt", "./sub/deep/c.txt", "./sub/deep"], "A changed file reopens its ancestors but not sibling folders")
    }

    func testMirrorUploadsContentsThenOnlyChangedFilesAndReplacesInPlace() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Fotos"); try tree(local)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [])
        XCTAssertThrowsError(try manager.add(local: local, account: .demo, folder: remote, path: []))
        try await wait { manager.mirrors.first?.lastSync != nil }
        XCTAssertEqual(try demo.list(remoteID).map(\.name).sorted(), ["a.txt", "sub"], "Contents land inside the remote folder, not a copy of the folder")
        let sub = try XCTUnwrap(demo.list(remoteID).first { $0.name == "sub" })
        XCTAssertEqual(try demo.list(sub.id).map(\.name).sorted(), ["b.txt", "deep"])
        XCTAssertEqual(manager.mirrors.first?.stamps.count, 3)
        XCTAssertTrue(manager.status(of: manager.mirrors[0]).hasPrefix("Sincronizado"))

        // Nothing changed: syncing again costs no transfer at all.
        let before = queue.items.count
        manager.syncNow(manager.mirrors[0].id)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(queue.items.count, before)

        // One file changed: only it is re-uploaded, replacing the remote copy rather than duplicating it.
        try Data("nuevo".utf8).write(to: local.appendingPathComponent("a.txt"))
        let previousSync = manager.mirrors[0].lastSync
        manager.syncNow(manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != previousSync }
        let job = try XCTUnwrap(queue.items.last)
        XCTAssertTrue(job.completedPaths.isSuperset(of: ["./sub/b.txt", "./sub/deep/c.txt", "./sub"]))
        XCTAssertEqual(job.verifiedFiles, 1, "Only the changed file travelled; the others were pre-marked completed")
        let files = try demo.list(remoteID).filter { $0.name == "a.txt" }
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(files[0].id)), Data("nuevo".utf8))

        manager.remove(manager.mirrors[0].id)
        XCTAssertTrue(manager.mirrors.isEmpty)
        XCTAssertTrue(MirrorManager(storeURL: manager.storeURL).mirrors.isEmpty)
    }
}
