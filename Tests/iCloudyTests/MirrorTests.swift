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
        XCTAssertEqual(Set(first.keys), ["a.txt", "sub", "sub/deep", "sub/b.txt", "sub/deep/c.txt"], "Symlinks are skipped")
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
        XCTAssertEqual(manager.mirrors.first?.stamps.count, 5)
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

    func testTheFirstSyncDoesNotReplaceWhatItFindsInTheDestination() async throws {
        // Until a mirror has uploaded something there is nothing to compare against, so whatever is already in the
        // destination belongs to somebody else. It used to be overwritten without a word.
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
        _ = try demo.add(name: "a.txt", parent: remoteID, content: Data("de otro".utf8))
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [])
        try await wait { queue.conflict != nil }
        XCTAssertEqual(queue.conflict?.name, "a.txt", "Pregunta en vez de pisar")
        queue.resolve(.copy, applyToBatch: true)
        try await wait { manager.mirrors.first?.lastSync != nil }
        XCTAssertEqual(try demo.list(remoteID).filter { $0.name.hasPrefix("a") }.count, 2, "El ajeno se conserva")

        // From the second sync on, what this mirror uploaded before is replaced without asking.
        try Data("cambiado".utf8).write(to: local.appendingPathComponent("a.txt"))
        let previous = manager.mirrors[0].lastSync
        manager.syncNow(manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != previous }
        XCTAssertNil(queue.conflict)
        XCTAssertNil(queue.items.last?.batchChoice)
        let files = try demo.list(remoteID)
        let stranger = try XCTUnwrap(files.first { $0.name == "a.txt" })
        let own = try XCTUnwrap(files.first { $0.name == "a (2).txt" })
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(stranger.id)), Data("de otro".utf8))
        XCTAssertEqual(try Data(contentsOf: demo.directory.appendingPathComponent(own.id)), Data("cambiado".utf8))
    }

    func testRestartingResumesTheInterruptedSyncInsteadOfPlanningASecond() async throws {
        // Closing the app pauses whatever was running. Planning a second sync left the first one orphaned in the
        // panel, with a plan made against a folder that had since moved on.
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
        try await wait { manager.mirrors.first?.activeTransferID != nil }
        let interrupted = try XCTUnwrap(manager.mirrors.first?.activeTransferID)
        queue.cancel(interrupted, pause: true)
        try await wait { queue.items.first { $0.id == interrupted }?.state == .paused }

        // What `start()` does when the app opens again.
        manager.start()
        try await wait { manager.mirrors.first?.lastSync != nil }
        XCTAssertEqual(queue.items.count, 1, "Un solo trabajo, el que estaba a medias: \(queue.items.map(\.state))")
        XCTAssertEqual(queue.items.first?.id, interrupted)
        XCTAssertEqual(queue.items.first?.state, .completed)
    }
    @MainActor private final class Fixture {
        let root: URL
        let local: URL
        let demo: DemoStore
        let remote: CloudFile
        let queue: TransferQueue
        let manager: MirrorManager
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            local = root.appendingPathComponent("local")
            try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
            demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
            let id = try demo.add(name: "Destination", parent: "root", folder: true)
            remote = try XCTUnwrap(demo.list("root").first { $0.id == id })
            queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
            let demo = self.demo
            queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
            manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
            manager.watching = false; manager.queue = queue
            let manager = self.manager
            queue.didFinish = { [weak manager] in manager?.handleFinished($0) }
        }
        func start() throws { try manager.add(local: local, account: .demo, folder: remote, path: []) }
    }
    func testSubsequentSyncAsksAboutNewStrangersAndDoesNotMarkSkippedFilesSynced() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        try Data("initial".utf8).write(to: f.local.appendingPathComponent("a"))
        try f.start(); try await wait { f.manager.mirrors.first?.lastSync != nil }
        let stranger = try f.demo.add(name: "b", parent: f.remote.id, content: Data("stranger".utf8))
        try Data("mine".utf8).write(to: f.local.appendingPathComponent("b"))
        let previous = f.manager.mirrors[0].lastSync
        f.manager.syncNow(f.manager.mirrors[0].id)
        try await wait { f.queue.conflict != nil }
        XCTAssertEqual(f.queue.conflict?.name, "b")
        f.queue.resolve(.skip, applyToBatch: false)
        try await wait { f.manager.mirrors[0].lastSync != previous }
        XCTAssertNil(f.manager.mirrors[0].stamps["b"])
        XCTAssertNil(f.manager.mirrors[0].remoteEntries["./b"])
        XCTAssertEqual(try String(contentsOf: f.demo.directory.appendingPathComponent(stranger)), "stranger")
    }
    func testRemoteEditIsNotSilentlyOverwrittenAndMappingSurvivesPersistence() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let source = f.local.appendingPathComponent("a")
        try Data("initial".utf8).write(to: source)
        try f.start(); try await wait { f.manager.mirrors.first?.lastSync != nil }
        let remote = try XCTUnwrap(f.demo.list(f.remote.id).first { $0.name == "a" })
        let restored = MirrorManager(storeURL: f.manager.storeURL)
        XCTAssertEqual(restored.mirrors[0].remoteEntries["./a"]?.id, remote.id)
        // Even with the same size/name/id, changing the remote version requires a new conflict decision.
        try f.demo.rename(remote.id, name: "a")
        try Data("changed".utf8).write(to: source)
        f.manager.syncNow(f.manager.mirrors[0].id)
        try await wait { f.queue.conflict != nil }
        XCTAssertEqual(try String(contentsOf: f.demo.directory.appendingPathComponent(remote.id)), "initial")
        f.queue.resolve(.copy, applyToBatch: false)
        try await wait { f.queue.items.last?.state == .completed }
        XCTAssertEqual(try String(contentsOf: f.demo.directory.appendingPathComponent(remote.id)), "initial")
        XCTAssertEqual(f.manager.mirrors[0].remoteEntries["./a"]?.name, "a (2)")
    }
    func testCopiedNestedFolderKeepsItsOwnDestinationAcrossSyncs() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let sub = f.local.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let source = sub.appendingPathComponent("a")
        try Data("mine".utf8).write(to: source)
        let strangerFolder = try f.demo.add(name: "sub", parent: f.remote.id, folder: true)
        let stranger = try f.demo.add(name: "a", parent: strangerFolder, content: Data("stranger".utf8))
        try f.start(); try await wait { f.queue.conflict != nil }
        f.queue.resolve(.copy, applyToBatch: false)
        try await wait { f.manager.mirrors.first?.lastSync != nil }
        let ownFolder = try XCTUnwrap(f.manager.mirrors[0].remoteEntries["./sub"])
        XCTAssertEqual(ownFolder.name, "sub (2)")
        let previous = f.manager.mirrors[0].lastSync
        try Data("updated".utf8).write(to: source)
        f.manager.syncNow(f.manager.mirrors[0].id)
        try await wait { f.manager.mirrors[0].lastSync != previous }
        XCTAssertNil(f.queue.conflict)
        XCTAssertEqual(try String(contentsOf: f.demo.directory.appendingPathComponent(stranger)), "stranger")
        let own = try XCTUnwrap(f.demo.list(ownFolder.id).first)
        XCTAssertEqual(try String(contentsOf: f.demo.directory.appendingPathComponent(own.id)), "updated")
    }
}
