import XCTest
@testable import iCloudy

/// "No subir lo que ya está": a file the destination already holds with the same checksum is not sent again.
@MainActor
final class SkipIdenticalTests: XCTestCase {
    private func queue(_ root: URL, clients: [String: DemoStore]) -> TransferQueue {
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.retryDelay = 0.001
        queue.client = { id in
            guard let store = clients[id] else { throw CloudError.message("unknown \(id)") }
            return CloudAPI(account: id == Account.demo.id ? .demo : stubbedAccount(.google, id: id), demo: store)
        }
        return queue
    }

    func testAnUploadSkipsTheFileTheDestinationAlreadyHas() async throws {
        let root = try temporaryRoot()
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .zero; demo.listsChecksums = true
        let folder = try demo.add(name: "Destino", parent: "root", folder: true)
        let existing = try demo.add(name: "a.txt", parent: folder, content: Data("igual".utf8))
        _ = try demo.add(name: "b.txt", parent: folder, content: Data("otro".utf8))
        let local = root.appendingPathComponent("Carpeta")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try Data("igual".utf8).write(to: local.appendingPathComponent("a.txt"))
        try Data("distinto".utf8).write(to: local.appendingPathComponent("b.txt"))
        let queue = queue(root, clients: [Account.demo.id: demo])
        var job = Transfer(name: "Carpeta", destination: "Demo", accountID: Account.demo.id, direction: .upload, localURL: local, parent: "root")
        // The folder merges into the existing one; the policy keeps both when the contents differ.
        job.names["."] = "Destino"; job.replacements["."] = folder
        job.options = TransferOptions(conflictPolicy: .keepBoth, skipIdentical: true)
        try queue.add([job])
        try await wait { queue.items.first?.finished == true }
        XCTAssertEqual(queue.items.first?.state, .completed)
        let names = try demo.list(folder).map(\.name).sorted()
        XCTAssertEqual(names, ["a.txt", "b (2).txt", "b.txt"], "a.txt was not sent again; b.txt differs and goes beside")
        XCTAssertEqual(try demo.list(folder).first { $0.name == "a.txt" }?.id, existing)
        let record = try XCTUnwrap(queue.items.first?.report["./a.txt"])
        XCTAssertEqual(record.outcome, .verified)
        XCTAssertNotNil(record.reason)
    }

    func testACopyBetweenCloudsComparesTheTwoListedChecksums() async throws {
        let root = try temporaryRoot()
        let a = try DemoStore(directory: root.appendingPathComponent("a")); a.latency = .zero; a.listsChecksums = true
        let b = try DemoStore(directory: root.appendingPathComponent("b")); b.latency = .zero; b.listsChecksums = true
        let target = try b.add(name: "Fotos", parent: "root", folder: true)
        let sourceID = try a.add(name: "foto.jpg", parent: "root", content: Data("bytes".utf8))
        let kept = try b.add(name: "foto.jpg", parent: target, content: Data("bytes".utf8))
        let queue = queue(root, clients: ["demo:a": a, "demo:b": b])
        let source = try XCTUnwrap(a.file(sourceID))
        var job = Transfer(name: "foto.jpg", destination: "B", accountID: "demo:a", direction: .transfer,
                           localURL: queue.scratchDirectory(for: UUID()), parent: target, file: source)
        job.targetAccountID = "demo:b"
        job.options = TransferOptions(skipIdentical: true)
        try queue.add([job])
        try await wait { queue.items.first?.finished == true }
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        XCTAssertNil(queue.conflict, "Nothing was asked")
        XCTAssertEqual(try b.list(target).map(\.id), [kept], "Nothing was copied")
    }

    func testOptionsWithoutTheFieldDoNotSkip() throws {
        XCTAssertFalse(try JSONDecoder().decode(TransferOptions.self, from: Data("{}".utf8)).skipIdentical)
        XCTAssertFalse(try JSONDecoder().decode(MirrorOptions.self, from: Data("{}".utf8)).skipIdentical)
    }
}
