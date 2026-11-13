import XCTest
@testable import iCloudy

/// The download mirror keeps a folder of this Mac as a copy of a cloud folder, through the queue's verified downloads.
@MainActor
final class DownloadMirrorTests: XCTestCase {
    private func file(_ id: String, _ name: String, size: Int64 = 1, t: TimeInterval = 100) -> CloudFile {
        CloudFile(id: id, name: name, mime: "text/plain", size: size, modified: Date(timeIntervalSince1970: t), webURL: nil, isFolder: false)
    }
    private func folder(_ id: String, _ name: String) -> CloudFile {
        CloudFile(id: id, name: name, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    private func stamp(_ size: Int64, _ t: TimeInterval = 100) -> FileStamp { FileStamp(size: size, modified: Date(timeIntervalSince1970: t)) }
    private func entry(_ f: CloudFile, local: FileStamp?) -> SyncEntry {
        SyncEntry(local: local, remoteID: f.id, remoteSize: f.size, remoteModified: f.modified, isFolder: false)
    }

    func testThePlannerSendsDownOnlyWhatChangedInTheCloud() {
        let same = file("s", "igual.txt"), edited = file("e", "editada.txt", size: 2, t: 200), mine = file("m", "mia.txt", size: 3, t: 300)
        let both = file("b", "ambos.txt", size: 4, t: 400), fresh = file("n", "nueva.txt"), adopt = file("a", "ya.txt", size: 7)
        let sub = folder("F", "Sub"), inner = file("i", "dentro.txt")
        let doc = CloudFile(id: "g", name: "Doc", mime: "application/vnd.google-apps.document", size: nil, modified: nil, webURL: nil, isFolder: false)
        let remote = ["igual.txt": same, "editada.txt": edited, "mia.txt": mine, "ambos.txt": both, "nueva.txt": fresh, "ya.txt": adopt,
                      "Sub": sub, "Sub/dentro.txt": inner, "Doc": doc, "x.tmp": file("t", "x.tmp")]
        let keys = Dictionary(uniqueKeysWithValues: remote.map { ($0.key, "./" + $0.key.replacingOccurrences(of: "/", with: "-")) })
        let local = ["igual.txt": stamp(1, 999), "mia.txt": stamp(3), "ambos.txt": stamp(9, 50), "ya.txt": stamp(7, 70),
                     "Sub": stamp(-1, 0), "Sub/dentro.txt": stamp(1), "solo-aqui.txt": stamp(5)]
        let baseline = ["igual.txt": entry(same, local: stamp(1)), "editada.txt": entry(file("e", "editada.txt"), local: stamp(1)),
                        "mia.txt": entry(file("m", "mia.txt"), local: stamp(3)), "ambos.txt": entry(file("b", "ambos.txt"), local: stamp(4)),
                        "Sub/dentro.txt": entry(inner, local: stamp(1)), "borrada.txt": entry(file("d", "borrada.txt"), local: stamp(1))]
        let rules = SyncExclusions().matcher(caseInsensitive: true)
        let plan = DownloadMirrorPlanner.plan(local: local, remote: remote, keys: keys, baseline: baseline, exclusions: rules)
        XCTAssertEqual(plan.downloads, ["editada.txt", "mia.txt", "nueva.txt"], "Deleted here and edited there comes back; unchanged ones do not")
        XCTAssertEqual(plan.owned, [keys["mia.txt"]!], "Its own untouched copy is replaced without asking")
        XCTAssertEqual(plan.conflicts, ["ambos.txt"])
        XCTAssertEqual(Set(plan.adopt.keys), ["ya.txt"], "The same file already here on a first sync is adopted")
        XCTAssertEqual(plan.forget, ["borrada.txt"], "Gone in the cloud: forgotten, the copy here stays")
        XCTAssertTrue(plan.completed.isSuperset(of: [keys["igual.txt"]!, keys["Sub"]!, keys["Sub/dentro.txt"]!, keys["Doc"]!, keys["x.tmp"]!]))
        XCTAssertFalse(plan.completed.contains(keys["editada.txt"]!))
        XCTAssertEqual(plan.excluded.map(\.path), ["x.tmp"])
        XCTAssertEqual(plan.names[keys["Sub/dentro.txt"]!], "dentro.txt")
        XCTAssertFalse(plan.nothingToDo)
    }

    private struct Fixture {
        let demo: DemoStore
        let queue: TransferQueue
        let manager: MirrorManager
        let local: URL
        let remote: String
    }
    private func fixture(policy: ConflictPolicy? = nil) async throws -> Fixture {
        let root = try temporaryRoot()
        let local = root.appendingPathComponent("Copia")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Origen", parent: "root", folder: true)
        _ = try demo.add(name: "a.txt", parent: remoteID, content: Data("a".utf8))
        let sub = try demo.add(name: "Sub", parent: remoteID, folder: true)
        _ = try demo.add(name: "b.txt", parent: sub, content: Data("bb".utf8))
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [], mode: .download)
        if let policy { manager.setOptions(MirrorOptions(conflictPolicy: policy), for: manager.mirrors[0].id) }
        try await wait { manager.mirrors.first?.lastSync != nil }
        return Fixture(demo: demo, queue: queue, manager: manager, local: local, remote: remoteID)
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
    private func syncAgain(_ f: Fixture) async throws {
        let previous = f.manager.mirrors[0].lastSync
        f.manager.syncNow(f.manager.mirrors[0].id)
        try await wait { f.manager.mirrors[0].lastSync != previous && f.manager.mirrors[0].activeTransferID == nil }
    }

    func testTheFolderBecomesACopyOfTheCloudAndFollowsIt() async throws {
        let f = try await fixture()
        XCTAssertEqual(try read(f.local.appendingPathComponent("a.txt")), "a", "Contents land in the folder itself")
        XCTAssertEqual(try read(f.local.appendingPathComponent("Sub/b.txt")), "bb")
        let job = try XCTUnwrap(f.queue.items.last)
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.verifiedFiles, 0, "The demo lists no checksum: checked by size")
        XCTAssertEqual(TransferReport(jobs: [job]).copied, 2)
        XCTAssertEqual(Set(f.manager.mirrors[0].baseline.keys), ["a.txt", "Sub/b.txt"])
        XCTAssertEqual(HistoryEntry(transfer: job).localURL?.resolvingSymlinksInPath().path, f.local.resolvingSymlinksInPath().path)

        // Nothing changed: no job at all.
        let count = f.queue.items.count
        try await syncAgain(f)
        XCTAssertEqual(f.queue.items.count, count)

        // An edit in the cloud replaces the copy without asking; a file only on the Mac is left alone.
        let a = try XCTUnwrap(f.demo.list(f.remote).first { $0.name == "a.txt" })
        let staged = f.local.deletingLastPathComponent().appendingPathComponent("staged"); try Data("a2".utf8).write(to: staged)
        _ = try await CloudAPI(account: .demo, demo: f.demo).resumableUpload(local: staged, parent: f.remote, name: "a.txt", replacing: a.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        try Data("mío".utf8).write(to: f.local.appendingPathComponent("local.txt"))
        try await syncAgain(f)
        XCTAssertNil(f.queue.conflict)
        XCTAssertEqual(try read(f.local.appendingPathComponent("a.txt")), "a2")
        XCTAssertEqual(try read(f.local.appendingPathComponent("local.txt")), "mío")
        XCTAssertEqual(f.manager.mirrors[0].lastReport?.downloaded, 1)

        // "Verificar lo copiado" finds the files where the mirror put them.
        let summary = try await f.queue.verifyCopied(try XCTUnwrap(f.queue.items.last).batchID)
        XCTAssertEqual(summary.missing, 0, summary.text)
        XCTAssertEqual(summary.checked, 1)

        // Deleted in the cloud: the copy here stays, and the mirror forgets it.
        try f.demo.trash(a.id)
        try await syncAgain(f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.local.appendingPathComponent("a.txt").path))
        XCTAssertNil(f.manager.mirrors[0].baseline["a.txt"])
    }

    func testAFileChangedOnBothSidesFollowsThePolicy() async throws {
        let f = try await fixture(policy: .thisSideWins)
        try Data("editado en el Mac".utf8).write(to: f.local.appendingPathComponent("a.txt"))
        let a = try XCTUnwrap(f.demo.list(f.remote).first { $0.name == "a.txt" })
        let staged = f.local.deletingLastPathComponent().appendingPathComponent("staged"); try Data("nube".utf8).write(to: staged)
        _ = try await CloudAPI(account: .demo, demo: f.demo).resumableUpload(local: staged, parent: f.remote, name: "a.txt", replacing: a.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        try await syncAgain(f)
        XCTAssertNil(f.queue.conflict, "The policy answered")
        XCTAssertEqual(try read(f.local.appendingPathComponent("a.txt")), "editado en el Mac", "The Mac wins")
        // Settled: the next run has nothing to do.
        let count = f.queue.items.count
        try await syncAgain(f)
        XCTAssertEqual(f.queue.items.count, count)
    }

    func testTheDryRunListsWhatWouldComeDownAndChangesNothing() async throws {
        let f = try await fixture()
        _ = try f.demo.add(name: "nueva.txt", parent: f.remote, content: Data("n".utf8))
        let preview = try await f.manager.preview(f.manager.mirrors[0].id)
        XCTAssertEqual(preview.changes(.download).map(\.path), ["nueva.txt"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.local.appendingPathComponent("nueva.txt").path))
    }

    func testDownloadMirrorsSurviveAReloadAndOlderRecordsStillRead() throws {
        let json = #"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/","mode":"download","baseline":{"a.txt":{"remoteID":"1","isFolder":false}}}"#
        let mirror = try JSONDecoder().decode(FolderMirror.self, from: Data(json.utf8))
        XCTAssertEqual(mirror.mode, .download)
        XCTAssertNil(mirror.pendingKeys)
        XCTAssertEqual(mirror.arrow, "←")
        let again = try JSONDecoder().decode(FolderMirror.self, from: JSONEncoder().encode(mirror))
        XCTAssertEqual(again.baseline["a.txt"]?.remoteID, "1")
        XCTAssertEqual(again.transferPolicy, nil, "Asks by default")
        var flipped = mirror; flipped.options.conflictPolicy = .thisSideWins
        XCTAssertEqual(flipped.transferPolicy, .otherSideWins, "The Mac is the destination of a download")
    }
}
