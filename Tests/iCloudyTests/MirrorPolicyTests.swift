import XCTest
@testable import iCloudy

/// Conflict policies: what a two-way sync and a one-way mirror do when both sides changed the same file.
@MainActor
final class MirrorPolicyTests: XCTestCase {
    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }
    private func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func testTheOneWayChoiceOfEachPolicy() {
        let old = Date(timeIntervalSince1970: 100), new = Date(timeIntervalSince1970: 200)
        XCTAssertNil(ConflictPolicy.ask.choice(incoming: new, existing: old, canReplace: true))
        XCTAssertEqual(ConflictPolicy.keepBoth.choice(incoming: new, existing: old, canReplace: true), .copy)
        XCTAssertEqual(ConflictPolicy.thisSideWins.choice(incoming: old, existing: new, canReplace: true), .replace)
        XCTAssertEqual(ConflictPolicy.thisSideWins.choice(incoming: old, existing: new, canReplace: false), .copy, "What cannot be replaced is kept beside")
        XCTAssertEqual(ConflictPolicy.otherSideWins.choice(incoming: new, existing: old, canReplace: true), .skip)
        XCTAssertEqual(ConflictPolicy.newestWins.choice(incoming: new, existing: old, canReplace: true), .replace)
        XCTAssertEqual(ConflictPolicy.newestWins.choice(incoming: old, existing: new, canReplace: true), .skip)
        XCTAssertNil(ConflictPolicy.newestWins.choice(incoming: nil, existing: new, canReplace: true), "Without dates, ask")
    }

    func testTheTwoWayResolutionOfEachPolicy() {
        let local = FileStamp(size: 1, modified: Date(timeIntervalSince1970: 300))
        let remote = CloudFile(id: "r", name: "a", mime: "x", size: 1, modified: Date(timeIntervalSince1970: 200), webURL: nil, isFolder: false)
        XCTAssertEqual(TwoWaySyncEngine.resolution(of: .keepBoth, local: local, remote: remote), .both)
        XCTAssertEqual(TwoWaySyncEngine.resolution(of: .newestWins, local: local, remote: remote), .local)
        XCTAssertEqual(TwoWaySyncEngine.resolution(of: .newestWins, local: FileStamp(size: 1, modified: .distantPast), remote: remote), .both)
        XCTAssertEqual(TwoWaySyncEngine.resolution(of: .thisSideWins, local: local, remote: remote), .local)
        XCTAssertEqual(TwoWaySyncEngine.resolution(of: .otherSideWins, local: local, remote: remote), .remote)
        XCTAssertEqual(TwoWaySyncEngine.resolution(of: .ask, local: local, remote: remote), .undecided)
    }

    /// Both sides edit the same file after a first sync, and the engine runs with `policy`.
    private func conflicted(_ policy: ConflictPolicy, decisions: [String: ConflictPolicy] = [:]) async throws -> (TwoWaySyncEngine, CloudAPI, URL, String) {
        let base = try temporaryRoot()
        let local = base.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let demo = try DemoStore(directory: base.appendingPathComponent("demo")); demo.latency = .zero
        let api = CloudAPI(account: .demo, demo: demo)
        let root = try demo.add(name: "Sync", parent: "root", folder: true)
        try write("v1", to: local.appendingPathComponent("nota.txt"))
        let first = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: [:])
        _ = try await first.run()
        try await Task.sleep(for: .milliseconds(20))
        try write("v2 local", to: local.appendingPathComponent("nota.txt"))
        let remoteFile = try XCTUnwrap(try demo.list(root).first)
        let staged = base.appendingPathComponent("staged.txt"); try write("v2 nube", to: staged)
        _ = try await api.resumableUpload(local: staged, parent: root, name: "nota.txt", replacing: remoteFile.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        let engine = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: first.baseline)
        engine.conflictPolicy = policy
        engine.decisions = decisions
        engine.trashLocally = { try FileManager.default.removeItem(at: $0) }
        return (engine, api, local, root)
    }

    func testTheMacWinningSendsItsVersionUpAndKeepsOneCopy() async throws {
        let (engine, api, local, root) = try await conflicted(.thisSideWins)
        let report = try await engine.run()
        XCTAssertEqual(report.conflicts, 1)
        let names = try await api.list(parent: root).map(\.name)
        XCTAssertEqual(names, ["nota.txt"], "No conflict copy")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: local.path), ["nota.txt"])
        let again = try await TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: engine.baseline).run()
        XCTAssertTrue(again.isEmpty, "Settled: \(again)")
    }

    func testTheCloudWinningTrashesTheMacVersionAndDownloads() async throws {
        let (engine, api, local, root) = try await conflicted(.otherSideWins)
        var trashed: [String] = []
        engine.trashLocally = { url in trashed.append(url.lastPathComponent); try FileManager.default.removeItem(at: url) }
        _ = try await engine.run()
        XCTAssertEqual(trashed, ["nota.txt"], "The losing version went to the Trash, not overwritten")
        XCTAssertEqual(try read(local.appendingPathComponent("nota.txt")), "v2 nube")
        let again = try await TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: engine.baseline).run()
        XCTAssertTrue(again.isEmpty, "Settled: \(again)")
    }

    func testAskingLeavesTheConflictUntilTheDecisionArrives() async throws {
        let (engine, api, local, root) = try await conflicted(.ask)
        let report = try await engine.run()
        XCTAssertEqual(report.unresolved, 1)
        XCTAssertEqual(engine.unresolvedConflicts, ["nota.txt"])
        XCTAssertEqual(try read(local.appendingPathComponent("nota.txt")), "v2 local", "Nothing touched")
        XCTAssertTrue(report.summary.contains("1"), report.summary)
        let decided = TwoWaySyncEngine(api: api, localRoot: local, remoteRoot: root, baseline: engine.baseline)
        decided.conflictPolicy = .ask
        decided.decisions = ["nota.txt": .thisSideWins]
        _ = try await decided.run()
        XCTAssertEqual(decided.resolvedConflicts, ["nota.txt"])
        XCTAssertTrue(decided.unresolvedConflicts.isEmpty)
        let names = try await api.list(parent: root).map(\.name)
        XCTAssertEqual(names, ["nota.txt"])
    }

    // MARK: - One-way mirrors

    private func uploadMirror(_ policy: ConflictPolicy) async throws -> (DemoStore, String, URL, TransferQueue) {
        let root = try temporaryRoot()
        let local = root.appendingPathComponent("Fotos")
        try write("mío", to: local.appendingPathComponent("a.txt"))
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        let remoteID = try demo.add(name: "Destino", parent: "root", folder: true)
        _ = try demo.add(name: "a.txt", parent: remoteID, content: Data("ajeno".utf8))
        let remote = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        try manager.add(local: local, account: .demo, folder: remote, path: [])
        manager.setOptions(MirrorOptions(conflictPolicy: policy), for: manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != nil }
        XCTAssertNil(queue.conflict, "The policy answered; nobody was asked")
        return (demo, remoteID, local, queue)
    }
    private func contents(_ demo: DemoStore, _ folder: String) throws -> [String: String] {
        Dictionary(uniqueKeysWithValues: try demo.list(folder).map { ($0.name, String(decoding: try Data(contentsOf: demo.directory.appendingPathComponent($0.id)), as: UTF8.self)) })
    }

    func testAnUploadMirrorThatKeepsBothUploadsBesideTheStrangersFile() async throws {
        let (demo, folder, _, _) = try await uploadMirror(.keepBoth)
        XCTAssertEqual(try contents(demo, folder), ["a.txt": "ajeno", "a (2).txt": "mío"])
    }

    func testAnUploadMirrorWhereTheMacWinsReplacesIt() async throws {
        let (demo, folder, _, _) = try await uploadMirror(.thisSideWins)
        XCTAssertEqual(try contents(demo, folder), ["a.txt": "mío"])
    }

    func testAnUploadMirrorWhereTheCloudWinsLeavesIt() async throws {
        let (demo, folder, _, queue) = try await uploadMirror(.otherSideWins)
        XCTAssertEqual(try contents(demo, folder), ["a.txt": "ajeno"])
        XCTAssertEqual(queue.items.last?.report.values.first { $0.path.hasSuffix("a.txt") }?.outcome, .skipped)
    }

    func testMirrorsWrittenBeforePoliciesKeepTheirOldBehaviour() throws {
        let json = #"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/","mode":"twoWay","lastReport":{"uploaded":2,"downloaded":1,"deletedRemote":0,"deletedLocal":0,"conflicts":0}}"#
        let mirror = try JSONDecoder().decode(FolderMirror.self, from: Data(json.utf8))
        XCTAssertNil(mirror.options.conflictPolicy)
        XCTAssertEqual(mirror.conflictPolicy, .keepBoth, "Two-way keeps both, as it always did")
        XCTAssertEqual(mirror.lastReport?.uploaded, 2)
        XCTAssertEqual(mirror.lastReport?.unresolved, 0)
        let oneWay = try JSONDecoder().decode(FolderMirror.self, from: Data(#"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/"}"#.utf8))
        XCTAssertEqual(oneWay.conflictPolicy, .ask, "One-way mirrors ask, as they always did")
        XCTAssertNil(oneWay.transferPolicy)
        let future = try JSONDecoder().decode(FolderMirror.self, from: Data(#"{"accountID":"a","remoteFolderID":"r","localURL":"file:///tmp/x/","options":{"conflictPolicy":"coin"},"conflictDecisions":{"a":"thisSideWins","b":"coin"}}"#.utf8))
        XCTAssertNil(future.options.conflictPolicy)
        XCTAssertEqual(future.conflictDecisions, ["a": .thisSideWins])
    }
}
