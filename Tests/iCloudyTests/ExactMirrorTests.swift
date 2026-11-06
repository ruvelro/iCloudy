import XCTest
@testable import iCloudy

/// "Espejo exacto": one-way mirrors that also carry deletions, to the destination's trash and behind the brake.
@MainActor
final class ExactMirrorTests: XCTestCase {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private struct Fixture {
        let demo: DemoStore
        let queue: TransferQueue
        let manager: MirrorManager
        let local: URL
        let remote: String
        @MainActor var id: UUID { manager.mirrors[0].id }
    }
    private func fixture(mode: FolderMirror.Mode, files: [String: String], remoteFiles: [String: String] = [:]) async throws -> Fixture {
        let root = try temporaryRoot()
        let local = root.appendingPathComponent("Carpeta")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        if mode == .upload { for (path, text) in files { try write(text, to: local.appendingPathComponent(path)) } }
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        manager.trashLocally = { try FileManager.default.removeItem(at: $0) }
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        if mode == .download {
            for (path, text) in files {
                var parent = remoteID
                for folder in path.split(separator: "/").dropLast() {
                    parent = try demo.list(parent).first { $0.name == folder }?.id ?? demo.add(name: String(folder), parent: parent, folder: true)
                }
                _ = try demo.add(name: String(path.split(separator: "/").last!), parent: parent, content: Data(text.utf8))
            }
        }
        for (name, text) in remoteFiles { _ = try demo.add(name: name, parent: remoteID, content: Data(text.utf8)) }
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [], mode: mode)
        manager.setOptions(MirrorOptions(exact: true), for: manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != nil && manager.mirrors.first?.activeTransferID == nil }
        return Fixture(demo: demo, queue: queue, manager: manager, local: local, remote: remoteID)
    }
    private func syncAgain(_ f: Fixture, applyingMassDeletion: Bool = false) async throws {
        let previous = f.manager.mirrors[0].lastSync
        f.manager.syncNow(f.id, applyingMassDeletion: applyingMassDeletion)
        try await wait { (f.manager.mirrors[0].lastSync != previous || f.manager.mirrors[0].lastError != nil) && f.manager.mirrors[0].activeTransferID == nil }
    }

    func testAnUploadMirrorSendsLocalDeletionsToTheCloudsTrashOnly() async throws {
        let f = try await fixture(mode: .upload, files: ["a.txt": "a", "b.txt": "b", "Sub/c.txt": "c"], remoteFiles: ["ajeno.txt": "x"])
        XCTAssertEqual(try f.demo.list(f.remote).map(\.name).sorted(), ["a.txt", "ajeno.txt", "b.txt", "Sub"].sorted())
        try FileManager.default.removeItem(at: f.local.appendingPathComponent("a.txt"))
        try FileManager.default.removeItem(at: f.local.appendingPathComponent("Sub"))
        let preview = try await f.manager.preview(f.id)
        XCTAssertEqual(preview.changes(.trashRemote).map(\.path), ["Sub", "Sub/c.txt", "a.txt"])
        try await syncAgain(f)
        XCTAssertNil(f.manager.mirrors[0].lastError)
        XCTAssertEqual(try f.demo.list(f.remote).map(\.name).sorted(), ["ajeno.txt", "b.txt"], "The stranger's file stays")
        XCTAssertEqual(Set(try f.demo.list(Collection.trash.rootID).map(\.name)), ["a.txt", "c.txt", "Sub"], "In the trash, not gone")
        XCTAssertEqual(f.manager.mirrors[0].lastReport?.deletedRemote, 3)
    }

    func testAFileEditedInTheCloudIsNotDeleted() async throws {
        let f = try await fixture(mode: .upload, files: ["a.txt": "a", "b.txt": "b"])
        let a = try XCTUnwrap(f.demo.list(f.remote).first { $0.name == "a.txt" })
        try await Task.sleep(for: .milliseconds(10))
        let staged = f.local.deletingLastPathComponent().appendingPathComponent("staged"); try write("editado", to: staged)
        _ = try await CloudAPI(account: .demo, demo: f.demo).resumableUpload(local: staged, parent: f.remote, name: "a.txt", replacing: a.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        try FileManager.default.removeItem(at: f.local.appendingPathComponent("a.txt"))
        f.manager.syncNow(f.id)
        try await wait { f.manager.mirrors[0].remoteEntries["./a.txt"] == nil }
        XCTAssertEqual(try f.demo.list(f.remote).map(\.name).sorted(), ["a.txt", "b.txt"], "Somebody else's edit wins over the deletion")
    }

    func testWipingMostOfTheFolderStopsUntilAllowed() async throws {
        var files: [String: String] = [:]
        for i in 0..<12 { files["f\(i).txt"] = "\(i)" }
        let f = try await fixture(mode: .upload, files: files)
        for i in 0..<12 { try FileManager.default.removeItem(at: f.local.appendingPathComponent("f\(i).txt")) }
        try await syncAgain(f)
        XCTAssertTrue(f.manager.mirrors[0].lastError?.contains("12") == true, f.manager.mirrors[0].lastError ?? "")
        XCTAssertEqual(try f.demo.list(f.remote).count, 12, "Nothing touched")
        let preview = try await f.manager.preview(f.id)
        XCTAssertNotNil(preview.massDeletion)
        XCTAssertEqual(preview.changes(.trashRemote).count, 12)
        f.manager.syncNow(f.id, applyingMassDeletion: true)
        try await wait { try f.demo.list(f.remote).isEmpty }
        XCTAssertEqual(try f.demo.list(f.remote).count, 0)
    }

    func testADownloadMirrorFollowsDeletionsAndPutsEditsBack() async throws {
        let f = try await fixture(mode: .download, files: ["a.txt": "a", "b.txt": "b", "Sub/c.txt": "c"])
        try write("mío", to: f.local.appendingPathComponent("propio.txt"))
        try write("cambiado aquí", to: f.local.appendingPathComponent("b.txt"))
        let listed = try f.demo.list(f.remote)
        try f.demo.trash(try XCTUnwrap(listed.first { $0.name == "a.txt" }).id)
        try f.demo.trash(try XCTUnwrap(listed.first { $0.name == "Sub" }).id)
        var trashed: [String] = []
        f.manager.trashLocally = { url in trashed.append(url.lastPathComponent); try FileManager.default.removeItem(at: url) }
        let preview = try await f.manager.preview(f.id)
        XCTAssertEqual(Set(preview.changes(.trashLocal).map(\.path)), ["a.txt", "b.txt", "Sub", "Sub/c.txt"])
        try await syncAgain(f)
        XCTAssertEqual(Set(trashed), ["a.txt", "b.txt", "c.txt", "Sub"])
        let names = try FileManager.default.contentsOfDirectory(atPath: f.local.path).sorted()
        XCTAssertEqual(names, ["b.txt", "propio.txt"], "What the person added stays")
        XCTAssertEqual(try String(contentsOf: f.local.appendingPathComponent("b.txt"), encoding: .utf8), "b", "Back as the cloud has it")
        XCTAssertEqual(f.manager.mirrors[0].lastReport?.deletedLocal, 3)
    }

    func testThePlannersOnlyDeleteWhatTheMirrorPutThere() {
        let entry = CloudFile(id: "1", name: "a", mime: "x", size: 1, modified: nil, webURL: nil, isFolder: false)
        let rules = SyncExclusions(patterns: ["*.log"]).matcher(caseInsensitive: true)
        let (files, folders) = ExactMirrorPlanner.remoteDeletions(entries: ["./a.txt": entry, "./b.log": entry, "./keep.txt": entry, "./Off/x.txt": entry],
                                                                 current: ["keep.txt": FileStamp(size: 1, modified: .distantPast)],
                                                                 excluded: ["Off": FileStamp(size: -1, modified: .distantPast)], exclusions: rules)
        XCTAssertEqual(files, ["a.txt"], "Excluded rules and excluded folders delete nothing")
        XCTAssertTrue(folders.isEmpty)
        XCTAssertThrowsError(try ExactMirrorPlanner.checkMassDeletion(10, of: 12, side: "x", allowed: false))
        XCTAssertNoThrow(try ExactMirrorPlanner.checkMassDeletion(10, of: 12, side: "x", allowed: true))
        XCTAssertNoThrow(try ExactMirrorPlanner.checkMassDeletion(9, of: 10, side: "x", allowed: false), "Below the minimum")
        let old = try? JSONDecoder().decode(MirrorOptions.self, from: Data(#"{"conflictPolicy":"keepBoth"}"#.utf8))
        XCTAssertEqual(old?.exact, false, "Older settings are not exact")
    }
}
