import XCTest
@testable import iCloudy

/// Exclusions as both planners see them: excluded items are never uploaded, downloaded, deleted or reported as
/// conflicts, and a rule added after an item was synced leaves that item where it is on both sides.
@MainActor
final class MirrorExclusionTests: XCTestCase {
    private func stamp(_ size: Int64, _ t: TimeInterval = 100) -> FileStamp { FileStamp(size: size, modified: Date(timeIntervalSince1970: t)) }
    private func remote(_ id: String, size: Int64 = 1, t: TimeInterval = 100, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: String(id.split(separator: "/").last ?? "x"), mime: folder ? "application/vnd.google-apps.folder" : "text/plain",
                  size: folder ? nil : size, modified: folder ? nil : Date(timeIntervalSince1970: t), webURL: nil, isFolder: folder)
    }
    private func agreed(_ local: FileStamp, _ file: CloudFile) -> SyncEntry {
        SyncEntry(local: local, remoteID: file.id, remoteSize: file.size, remoteModified: file.modified, isFolder: false)
    }
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out"); throw CloudError.message("timeout")
    }
    private let rules = SyncExclusions(patterns: ["*.log", "build/"]).matcher(caseInsensitive: true)

    // MARK: - Two-way planner

    func testExcludedItemsAreNeitherTransferredNorDeletedNorConflicts() throws {
        let log = remote("log"), shared = remote("s")
        let plan = try TwoWayPlanner.plan(
            local: [".DS_Store": stamp(5), "build": stamp(-1, 0), "build/app.o": stamp(3), "a.log": stamp(9, 900), "x.txt": stamp(1)],
            remote: ["Thumbs.db": remote("t"), "a.log": remote("log", size: 2, t: 950), "nube.log": remote("n"), "x.txt": shared],
            baseline: ["a.log": agreed(stamp(1), log), "x.txt": agreed(stamp(1), shared)],
            exclusions: rules)
        XCTAssertTrue(plan.isEmpty, "Nada que hacer: todo lo distinto está excluido. \(plan)")
        // Without the rules the same trees are full of work, which is what makes the empty plan meaningful.
        let unruled = try TwoWayPlanner.plan(
            local: [".DS_Store": stamp(5), "a.log": stamp(9, 900), "x.txt": stamp(1)],
            remote: ["Thumbs.db": remote("t"), "a.log": remote("log", size: 2, t: 950), "x.txt": shared],
            baseline: ["a.log": agreed(stamp(1), log), "x.txt": agreed(stamp(1), shared)])
        XCTAssertEqual(Set(unruled), [.upload(".DS_Store", replacing: nil), .download("Thumbs.db", remote("t")), .conflict("a.log", remote("log", size: 2, t: 950))])
    }

    func testARuleAddedAfterSyncingDeletesNothingOnEitherSide() throws {
        let a = remote("a"), b = remote("b")
        let baseline = ["notas/a.log": agreed(stamp(1), a), "notas/b.log": agreed(stamp(1), b),
                        "notas": SyncEntry(local: stamp(-1, 0), remoteID: "N", isFolder: true)]
        // a.log was removed on the Mac and b.log in the cloud after the rule went in: both removals stay local to
        // their side, because neither file is looked at any more.
        let plan = try TwoWayPlanner.plan(local: ["notas": stamp(-1, 0), "notas/b.log": stamp(1)],
                                          remote: ["notas": remote("N", folder: true), "notas/a.log": a],
                                          baseline: baseline, exclusions: rules)
        XCTAssertTrue(plan.isEmpty, "\(plan)")
        // The baseline keeps describing them, so dropping the rule later carries on from where they were.
        let again = try TwoWayPlanner.plan(local: ["notas": stamp(-1, 0), "notas/b.log": stamp(1)],
                                           remote: ["notas": remote("N", folder: true), "notas/a.log": a], baseline: baseline)
        XCTAssertEqual(Set(again), [.deleteRemote("notas/a.log", a), .deleteLocal("notas/b.log")])
    }

    func testAFolderHoldingSomethingExcludedIsEmptiedInsteadOfRemoved() throws {
        let file = remote("D/a"), folder = remote("D", folder: true)
        let baseline: [String: SyncEntry] = ["Docs": SyncEntry(local: stamp(-1, 0), remoteID: "D", isFolder: true), "Docs/a.txt": agreed(stamp(1), file)]
        // Removed in the cloud; on the Mac it still holds a file nobody syncs.
        let kept = try TwoWayPlanner.plan(local: ["Docs": stamp(-1, 0), "Docs/a.txt": stamp(1), "Docs/privado.log": stamp(4)],
                                          remote: [:], baseline: baseline, exclusions: rules)
        XCTAssertEqual(kept, [.deleteLocal("Docs/a.txt")], "El archivo excluido y su carpeta se quedan")
        // .DS_Store only describes the folder: it does not keep it alive.
        let gone = try TwoWayPlanner.plan(local: ["Docs": stamp(-1, 0), "Docs/a.txt": stamp(1), "Docs/.DS_Store": stamp(4)],
                                          remote: [:], baseline: baseline, exclusions: rules)
        XCTAssertEqual(gone, [.deleteLocal("Docs")])
        // The same in the other direction.
        let remoteKept = try TwoWayPlanner.plan(local: [:], remote: ["Docs": folder, "Docs/a.txt": file, "Docs/x.log": remote("D/x")],
                                                baseline: baseline, exclusions: rules)
        XCTAssertEqual(remoteKept, [.deleteRemote("Docs/a.txt", file)])
    }

    // MARK: - Two-way engine

    func testTheEngineLeavesExcludedItemsAloneOnBothSides() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("excl-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let local = base.appendingPathComponent("local")
        let demo = try DemoStore(directory: base.appendingPathComponent("demo")); demo.latency = .zero
        let api = CloudAPI(account: .demo, demo: demo)
        let root = try demo.add(name: "Sync", parent: "root", folder: true)
        try write("hola", to: local.appendingPathComponent("a.txt"))
        try write("meta", to: local.appendingPathComponent(".DS_Store"))
        try write("lock", to: local.appendingPathComponent("~$informe.docx"))
        try write("obj", to: local.appendingPathComponent("build/app.o"))
        try write("registro", to: local.appendingPathComponent("sesion.log"))
        _ = try demo.add(name: "Thumbs.db", parent: root, content: Data("win".utf8))
        let remoteBuild = try demo.add(name: "build", parent: root, folder: true)
        _ = try demo.add(name: "otro.o", parent: remoteBuild, content: Data("x".utf8))

        let engine = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: [:])
        engine.exclusions = rules
        engine.trashLocally = { try FileManager.default.removeItem(at: $0) }
        let report = try await engine.run()
        XCTAssertEqual(report.uploaded, 1); XCTAssertEqual(report.downloaded, 0); XCTAssertEqual(report.conflicts, 0)
        XCTAssertEqual(try demo.list(root).map(\.name).sorted(), ["Thumbs.db", "a.txt", "build"])
        XCTAssertEqual(try demo.list(remoteBuild).map(\.name), ["otro.o"], "Lo de la nube en una carpeta excluida no se toca")
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("Thumbs.db").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: local.appendingPathComponent("build/otro.o").path))
        XCTAssertEqual(Set(engine.baseline.keys), ["a.txt"])

        // A rule added later: a.txt is now excluded, then deleted on the Mac. The cloud keeps it, out of the bin.
        let later = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: engine.baseline)
        later.exclusions = SyncExclusions(patterns: ["*.log", "build/", "a.txt"]).matcher(caseInsensitive: true)
        try FileManager.default.removeItem(at: local.appendingPathComponent("a.txt"))
        let quiet = try await later.run()
        XCTAssertTrue(quiet.isEmpty, "\(quiet)")
        XCTAssertTrue(try demo.list(root).contains { $0.name == "a.txt" })
        XCTAssertTrue(try demo.list(Collection.trash.rootID).isEmpty)
        XCTAssertNotNil(later.baseline["a.txt"], "La línea base no se olvida de lo que ahora está excluido")
    }

    // MARK: - One-way mirror

    func testAOneWayMirrorNeverUploadsExcludedItems() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("Proyecto")
        try write("a", to: local.appendingPathComponent("a.txt"))
        try write("meta", to: local.appendingPathComponent(".DS_Store"))
        try write("meta", to: local.appendingPathComponent("sub/.DS_Store"))
        try write("b", to: local.appendingPathComponent("sub/b.txt"))
        try write("scratch", to: local.appendingPathComponent("sub/x.tmp"))
        try write("dep", to: local.appendingPathComponent("node_modules/lib/index.js"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [])
        let id = manager.mirrors[0].id
        // The rules are set before the first run gets going: both happen on the main actor, in this order.
        try manager.setExclusions(SyncExclusions(patterns: ["node_modules/"]), for: id)
        try await wait { manager.mirrors.first?.lastSync != nil }
        XCTAssertEqual(try demo.list(remoteID).map(\.name).sorted(), ["a.txt", "sub"])
        let sub = try XCTUnwrap(demo.list(remoteID).first { $0.name == "sub" })
        XCTAssertEqual(try demo.list(sub.id).map(\.name), ["b.txt"])
        XCTAssertEqual(Set(manager.mirrors[0].stamps.keys), ["a.txt", "sub", "sub/b.txt"])

        // Excluding a file that was already uploaded neither deletes it nor sends its later edits.
        let uploaded = try XCTUnwrap(demo.list(remoteID).first { $0.name == "a.txt" })
        try manager.setExclusions(SyncExclusions(patterns: ["node_modules/", "a.txt"]), for: id)
        try await Task.sleep(for: .milliseconds(20))
        try await wait { manager.mirrors[0].activeTransferID == nil && !manager.pending.contains(id) }
        try write("editado", to: local.appendingPathComponent("a.txt"))
        manager.syncNow(id)
        try await Task.sleep(for: .milliseconds(150))
        try await wait { manager.mirrors[0].activeTransferID == nil }
        XCTAssertEqual(try String(contentsOf: demo.directory.appendingPathComponent(uploaded.id), encoding: .utf8), "a")
        XCTAssertTrue(try demo.list(remoteID).contains { $0.id == uploaded.id })
    }
}
