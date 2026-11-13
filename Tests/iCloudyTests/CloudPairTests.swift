import XCTest
@testable import iCloudy

/// Two cloud folders kept in step, through the two-way planner, with this Mac as a stage for each copy.
@MainActor
final class CloudPairTests: XCTestCase {
    private struct Fixture {
        let a: DemoStore, b: DemoStore
        let folderA: String, folderB: String
        let queue: TransferQueue
        let manager: MirrorManager
        @MainActor var id: UUID { manager.mirrors[0].id }
    }
    private func fixture(policy: ConflictPolicy? = nil) async throws -> (Fixture, Box<[Transfer]>) {
        let root = try temporaryRoot()
        let a = try DemoStore(directory: root.appendingPathComponent("a")); a.latency = .zero
        let b = try DemoStore(directory: root.appendingPathComponent("b")); b.latency = .zero
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.scratchRoot = root.appendingPathComponent("scratch")
        let accounts = ["demo:a": a, "demo:b": b]
        queue.client = { id in CloudAPI(account: stubbedAccount(.google, id: id), demo: accounts[id]!) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        let recorded = Box<[Transfer]>([])
        manager.didRecordRun = { recorded.value.append($0) }
        let folderA = try a.add(name: "Uno", parent: "root", folder: true)
        let folderB = try b.add(name: "Dos", parent: "root", folder: true)
        _ = try a.add(name: "a.txt", parent: folderA, content: Data("de A".utf8))
        let sub = try b.add(name: "Sub", parent: folderB, folder: true)
        _ = try b.add(name: "b.txt", parent: sub, content: Data("de B".utf8))
        try manager.addPair(first: stubbedAccount(.google, id: "demo:a"), firstFolder: folderA, firstName: "A / Uno",
                            second: stubbedAccount(.google, id: "demo:b"), secondFolder: folderB, secondName: "B / Dos")
        if let policy { manager.setOptions(MirrorOptions(conflictPolicy: policy), for: manager.mirrors[0].id) }
        try await wait { manager.mirrors.first?.lastSync != nil }
        return (Fixture(a: a, b: b, folderA: folderA, folderB: folderB, queue: queue, manager: manager), recorded)
    }
    private func tree(_ store: DemoStore, _ folder: String, prefix: String = "") throws -> [String: String] {
        var result: [String: String] = [:]
        for item in try store.list(folder) {
            let path = prefix.isEmpty ? item.name : prefix + "/" + item.name
            if item.isFolder { result.merge(try tree(store, item.id, prefix: path)) { x, _ in x } }
            else { result[path] = String(decoding: try Data(contentsOf: store.directory.appendingPathComponent(item.id)), as: UTF8.self) }
        }
        return result
    }
    private func syncAgain(_ f: Fixture) async throws {
        let previous = f.manager.mirrors[0].lastSync
        f.manager.syncNow(f.id)
        try await wait { f.manager.mirrors[0].lastSync != previous }
        XCTAssertNil(f.manager.mirrors[0].lastError)
    }
    private func replace(_ store: DemoStore, _ folder: String, _ name: String, with text: String) async throws {
        let file = try XCTUnwrap(store.list(folder).first { $0.name == name })
        let staged = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staged) }
        try Data(text.utf8).write(to: staged)
        _ = try await CloudAPI(account: .demo, demo: store).resumableUpload(local: staged, parent: folder, name: name, replacing: file.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
    }

    func testBothFoldersEndTheSameAndFollowEachOther() async throws {
        let (f, recorded) = try await fixture()
        let expected = ["a.txt": "de A", "Sub/b.txt": "de B"]
        XCTAssertEqual(try tree(f.a, f.folderA), expected)
        XCTAssertEqual(try tree(f.b, f.folderB), expected)
        XCTAssertEqual(recorded.value.count, 1, "The run reached the history")
        XCTAssertEqual(recorded.value.first?.direction, .transfer)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.manager.mirrors[0].localURL.path), "Nothing staged is left behind")

        // Nothing changed: nothing moves.
        try await syncAgain(f)
        XCTAssertTrue(f.manager.mirrors[0].lastReport?.isEmpty == true, f.manager.mirrors[0].lastReport?.summary ?? "")

        // An edit on one side and a deletion on the other.
        try await Task.sleep(for: .milliseconds(10))
        try await replace(f.b, f.folderB, "a.txt", with: "editado en B")
        let a = try XCTUnwrap(f.a.list(f.folderA).first { $0.name == "Sub" })
        try f.a.trash(try XCTUnwrap(f.a.list(a.id).first).id)
        try await syncAgain(f)
        XCTAssertEqual(try tree(f.a, f.folderA), ["a.txt": "editado en B"])
        XCTAssertEqual(try tree(f.b, f.folderB), ["a.txt": "editado en B"], "The deletion went to B's trash")
        XCTAssertFalse(try f.b.list(Collection.trash.rootID).isEmpty)
    }

    func testAConflictKeepsBothVersionsInBothFolders() async throws {
        let (f, _) = try await fixture()
        try await Task.sleep(for: .milliseconds(10))
        try await replace(f.a, f.folderA, "a.txt", with: "A2")
        try await replace(f.b, f.folderB, "a.txt", with: "B2")
        try await syncAgain(f)
        let first = try tree(f.a, f.folderA), second = try tree(f.b, f.folderB)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first["a.txt"], "B2")
        XCTAssertEqual(first.filter { $0.key.contains("conflicto") }.values.sorted(), ["A2"])
        try await syncAgain(f)
        XCTAssertTrue(f.manager.mirrors[0].lastReport?.isEmpty == true, "Settled")
    }

    func testTheFirstFolderWinningReplacesTheSecond() async throws {
        let (f, _) = try await fixture(policy: .thisSideWins)
        try await Task.sleep(for: .milliseconds(10))
        try await replace(f.a, f.folderA, "a.txt", with: "A2")
        try await replace(f.b, f.folderB, "a.txt", with: "B2")
        try await syncAgain(f)
        XCTAssertEqual(try tree(f.b, f.folderB)["a.txt"], "A2")
        XCTAssertEqual(try tree(f.b, f.folderB).count, 2, "No conflict copy")
    }

    func testPairsRoundTripAndOlderMirrorsHaveNoPeer() throws {
        var mirror = FolderMirror(accountID: "a", remoteFolderID: "r", remoteName: "B / Dos", localURL: URL(fileURLWithPath: "/tmp/pair"))
        mirror.mode = .cloudPair; mirror.peerAccountID = "b"; mirror.peerFolderID = "s"; mirror.peerName = "A / Uno"
        let again = try JSONDecoder().decode(FolderMirror.self, from: JSONEncoder().encode(mirror))
        XCTAssertEqual(again.mode, .cloudPair)
        XCTAssertEqual(again.peerFolderID, "s")
        XCTAssertEqual(again.title, "A / Uno")
        XCTAssertTrue(again.isTwoWay)
        XCTAssertEqual(again.conflictPolicy, .keepBoth)
        let old = try JSONDecoder().decode(FolderMirror.self, from: Data(#"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/"}"#.utf8))
        XCTAssertNil(old.peerAccountID)
    }
}
