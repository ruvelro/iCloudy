import XCTest
@testable import iCloudy

/// The pending-changes view is a dry run of the real planners: it must change nothing and say exactly what the
/// next sync then does.
@MainActor
final class MirrorPreviewTests: XCTestCase {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out"); throw CloudError.message("timeout")
    }
    /// Every path and its contents, to prove a preview left a folder exactly as it was.
    private func contents(_ root: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for (path, stamp) in try MirrorPlanner.stamps(of: root) where stamp.size != -1 {
            result[path] = try Data(contentsOf: root.appendingPathComponent(path))
        }
        return result
    }
    private func remoteTree(_ demo: DemoStore, _ folder: String, prefix: String = "") throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try demo.list(folder) {
            let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
            result[path] = item.id + "|" + String(item.size ?? -1) + "|" + String(item.modified?.timeIntervalSince1970 ?? 0)
            if item.isFolder { result.merge(try remoteTree(demo, item.id, prefix: path)) { a, _ in a } }
        }
        return result
    }

    func testTheTwoWayDryRunChangesNothingAndIsThePlanTheRunCarriesOut() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = base.appendingPathComponent("local")
        let demo = try DemoStore(directory: base.appendingPathComponent("demo")); demo.latency = .zero
        let api = CloudAPI(account: .demo, demo: demo)
        let root = try demo.add(name: "Sync", parent: "root", folder: true)
        for name in ["queda.txt", "se-borra-en-mac.txt", "se-borra-en-nube.txt", "conflicto.txt", "editado-en-nube.txt"] {
            try write(name, to: local.appendingPathComponent(name))
        }
        let rules = SyncExclusions(patterns: ["*.log"]).matcher(caseInsensitive: true)
        let first = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: [:])
        first.exclusions = rules
        _ = try await first.run()

        // Every kind of change at once, plus excluded items on both sides.
        try await Task.sleep(for: .milliseconds(20))
        try write("nuevo", to: local.appendingPathComponent("Nueva/nuevo.txt"))
        try FileManager.default.removeItem(at: local.appendingPathComponent("se-borra-en-mac.txt"))
        try write("mac", to: local.appendingPathComponent("conflicto.txt"))
        try write("registro", to: local.appendingPathComponent("local.log"))
        try write("meta", to: local.appendingPathComponent(".DS_Store"))
        let listed = try demo.list(root)
        try demo.trash(try XCTUnwrap(listed.first { $0.name == "se-borra-en-nube.txt" }).id)
        let staged = base.appendingPathComponent("staged"); try write("nube", to: staged)
        for name in ["conflicto.txt", "editado-en-nube.txt"] {
            let file = try XCTUnwrap(listed.first { $0.name == name })
            _ = try await api.resumableUpload(local: staged, parent: root, name: name, replacing: file.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        }
        _ = try demo.add(name: "remoto.txt", parent: root, content: Data("r".utf8))
        _ = try demo.add(name: "servidor.log", parent: root, content: Data("s".utf8))

        let localBefore = try contents(local), remoteBefore = try remoteTree(demo, root)
        let engine = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: first.baseline)
        engine.exclusions = rules
        engine.trashLocally = { try FileManager.default.removeItem(at: $0) }
        let preview = try await engine.preview()
        XCTAssertEqual(try contents(local), localBefore, "La vista previa no toca el Mac")
        XCTAssertEqual(try remoteTree(demo, root), remoteBefore, "Ni la nube")
        XCTAssertEqual(engine.baseline, first.baseline, "Ni la línea base")
        XCTAssertNil(preview.massDeletion)

        XCTAssertEqual(preview.changes(.upload).map(\.path), ["Nueva", "Nueva/nuevo.txt"])
        XCTAssertEqual(preview.changes(.download).map(\.path), ["editado-en-nube.txt", "remoto.txt"])
        XCTAssertEqual(preview.changes(.trashRemote).map(\.path), ["se-borra-en-mac.txt"])
        XCTAssertEqual(preview.changes(.trashLocal).map(\.path), ["se-borra-en-nube.txt"])
        XCTAssertEqual(preview.changes(.conflict).map(\.path), ["conflicto.txt"])
        XCTAssertEqual(preview.changes(.excluded).map(\.path), [".DS_Store", "local.log", "servidor.log"])
        XCTAssertTrue(preview.changes(.upload).first?.isFolder == true)

        // The run then carries out exactly that plan.
        let report = try await engine.run()
        XCTAssertEqual(Set(engine.lastPlan), Set(preview.actions))
        XCTAssertEqual(engine.lastPlan.count, preview.actions.count)
        XCTAssertEqual(report.uploaded, 1); XCTAssertEqual(report.downloaded, 2); XCTAssertEqual(report.conflicts, 1)
        XCTAssertEqual(report.deletedLocal, 1); XCTAssertEqual(report.deletedRemote, 1)
        let after = try await engine.preview()
        XCTAssertTrue(after.isEmpty, "\(after.changes)")
    }

    func testAPreviewShowsWhatARefusedMassDeletionWouldRemove() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = base.appendingPathComponent("local")
        let demo = try DemoStore(directory: base.appendingPathComponent("demo")); demo.latency = .zero
        let api = CloudAPI(account: .demo, demo: demo)
        let root = try demo.add(name: "Sync", parent: "root", folder: true)
        for i in 0..<12 { try write("\(i)", to: local.appendingPathComponent("f\(i).txt")) }
        let first = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: [:])
        _ = try await first.run()
        try FileManager.default.removeItem(at: local)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)

        let preview = try await TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: first.baseline).preview()
        XCTAssertNotNil(preview.massDeletion)
        XCTAssertEqual(preview.changes(.trashRemote).count, 12)
        XCTAssertEqual(try demo.list(root).count, 12, "Nada se ha borrado")
    }

    func testTheOneWayDryRunListsExactlyWhatTheUploadSends() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Fotos")
        try write("a", to: local.appendingPathComponent("a.txt"))
        try write("b", to: local.appendingPathComponent("sub/b.txt"))
        try write("c", to: local.appendingPathComponent("sub/deep/c.txt"))
        try write("meta", to: local.appendingPathComponent("sub/.DS_Store"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        queue.setOnline(false)
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [])
        let id = manager.mirrors[0].id
        manager.setPaused(true, for: id)

        let initial = try await manager.preview(id)
        XCTAssertTrue(initial.oneWay)
        XCTAssertEqual(Set(initial.changes(.upload).map(\.path)), ["a.txt", "sub", "sub/b.txt", "sub/deep", "sub/deep/c.txt"])
        XCTAssertEqual(initial.changes(.excluded).map(\.path), ["sub/.DS_Store"])
        XCTAssertTrue(initial.changes(.download).isEmpty && initial.changes(.trashRemote).isEmpty && initial.changes(.trashLocal).isEmpty,
                      "Un reflejo de un sentido nunca baja ni borra")

        queue.setOnline(true)
        manager.setPaused(false, for: id)
        try await wait { manager.mirrors[0].lastSync != nil }
        let synced = try await manager.preview(id)
        XCTAssertTrue(synced.isEmpty, "\(synced.changes)")

        // One edited file: the preview names it, and the job then marks everything else completed.
        try write("nuevo", to: local.appendingPathComponent("sub/deep/c.txt"))
        let preview = try await manager.preview(id)
        XCTAssertEqual(preview.changes(.upload).map(\.path), ["sub/deep/c.txt"])
        // Offline, the planned job waits in the queue untouched, so its plan can be read as the sync made it.
        queue.setOnline(false)
        let previous = manager.mirrors[0].lastSync
        manager.syncNow(id)
        try await wait { manager.mirrors[0].activeTransferID != nil }
        let job = try XCTUnwrap(queue.items.first { $0.id == manager.mirrors[0].activeTransferID })
        let files = try MirrorPlanner.stamps(of: local).filter { $0.value.size != -1 }.map(\.key)
        let planned = Set(files.filter { !job.completedPaths.contains("./" + $0) })
        XCTAssertEqual(planned, Set(preview.changes(.upload).map(\.path) + preview.changes(.excluded).map(\.path)),
                       "Lo que el trabajo no da por hecho es lo anunciado, más lo excluido, que el recorrido salta")
        queue.setOnline(true)
        try await wait { manager.mirrors[0].lastSync != previous }
        let done = try XCTUnwrap(queue.items.first { $0.id == job.id })
        XCTAssertEqual(done.verifiedFiles + done.unverifiedFiles, 1, "Subió justo lo anunciado")
    }
}
