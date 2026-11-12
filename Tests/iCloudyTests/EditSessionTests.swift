import XCTest
@testable import iCloudy

/// "Editar y subir los cambios": a watched copy of a remote file, uploaded over the original on every save, and
/// never over somebody else's work.
@MainActor
final class EditSessionTests: XCTestCase {
    private var root: URL!
    private var demo: DemoStore!
    private var queue: TransferQueue!
    private var editing: EditSessions!
    private var opened: [URL] = []
    private var notes: [String] = []

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("edit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        demo = try DemoStore(directory: root.appendingPathComponent("demo"))
        let demo = demo!
        queue = TransferQueue(storeURL: root.appendingPathComponent("transfers.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        editing = make()
        opened = []; notes = []
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }

    private func make() -> EditSessions {
        let demo = demo!
        let sessions = EditSessions(storeURL: root.appendingPathComponent("editing.json"), root: root.appendingPathComponent("Editing"))
        sessions.watching = false
        sessions.queue = queue
        sessions.client = { _ in CloudAPI(account: .demo, demo: demo) }
        sessions.open = { [weak self] url in self?.opened.append(url); return true }
        sessions.notify = { [weak self] in self?.notes.append($0) }
        queue.didFinish = { [weak sessions] in sessions?.handleFinished($0) }
        return sessions
    }
    private func remote(_ name: String, _ text: String) throws -> CloudFile {
        let id = try demo.add(name: name, parent: "root", content: Data(text.utf8))
        return try XCTUnwrap(demo.file(id))
    }
    private func content(of id: String) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent("demo").appendingPathComponent(id)), as: UTF8.self)
    }
    private func settle() async throws {
        for _ in 0..<500 {
            if !queue.isWorking, !queue.items.contains(where: { [.queued, .running].contains($0.state) }), !editing.sessions.contains(where: { $0.state == .uploading }) {
                // The session reads the new description of the file right after its upload.
                try await Task.sleep(for: .milliseconds(30))
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the upload")
    }
    /// Saves the way an application does, with a date that is certain to differ from the one before.
    private func save(_ text: String, to session: EditSession, at offset: TimeInterval = 5) throws {
        try Data(text.utf8).write(to: session.localURL, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(offset)], ofItemAtPath: session.localPath)
    }

    func testOpeningDownloadsACopyAndHandsItToItsApplication() async throws {
        let file = try remote("nota.txt", "hola")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        let session = try XCTUnwrap(editing.sessions.first)
        XCTAssertEqual(session.state, .watching)
        XCTAssertEqual(try String(contentsOf: session.localURL), "hola")
        XCTAssertEqual(opened, [session.localURL])
        XCTAssertEqual(session.localURL.lastPathComponent, "nota.txt", "The application sees the file's own name")
        XCTAssertFalse(editing.hasUnsavedChanges(session.id))

        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        XCTAssertEqual(editing.sessions.count, 1, "Editing it again opens the same copy")
        XCTAssertEqual(opened.count, 2)
    }

    func testASaveReplacesTheRemoteFileAndTheNextOneDoesToo() async throws {
        let file = try remote("nota.txt", "hola")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        var session = try XCTUnwrap(editing.sessions.first)
        await editing.check(session.id)
        XCTAssertTrue(queue.items.isEmpty, "Nothing was saved, so nothing travels")

        try save("hola, mundo", to: session)
        XCTAssertTrue(editing.hasUnsavedChanges(session.id))
        await editing.check(session.id)
        try await settle()
        XCTAssertEqual(queue.items.first?.state, .completed, queue.items.first?.detail ?? "")
        XCTAssertEqual(try content(of: file.id), "hola, mundo")
        XCTAssertEqual(try demo.list("root").filter { $0.name == "nota.txt" }.count, 1, "Replaced, not duplicated")
        session = try XCTUnwrap(editing.sessions.first)
        XCTAssertEqual(session.state, .watching); XCTAssertNotNil(session.lastUpload)
        XCTAssertFalse(editing.hasUnsavedChanges(session.id))
        XCTAssertTrue(notes.isEmpty)

        try save("tercera versión", to: session, at: 10)
        await editing.check(session.id)
        try await settle()
        XCTAssertEqual(try content(of: file.id), "tercera versión", "The session knows the file as its own upload left it")
        XCTAssertEqual(queue.items.count, 2)
    }

    func testASaveNeverOverwritesWhatSomebodyElseChanged() async throws {
        let file = try remote("informe.txt", "original")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        let session = try XCTUnwrap(editing.sessions.first)
        // Someone else replaces the file while it is open here.
        let other = root.appendingPathComponent("otro.txt")
        try Data("lo que escribió otra persona".utf8).write(to: other)
        _ = try await demo.upload(local: other, parent: "root", name: "informe.txt", replacing: file.id, checkpoint: nil, save: { _ in }, progress: { _, _ in })

        try save("lo mío", to: session)
        await editing.check(session.id)
        try await settle()
        XCTAssertEqual(try content(of: file.id), "lo que escribió otra persona", "The original is left as it was found")
        let listed = try demo.list("root")
        let copy = try XCTUnwrap(listed.first { $0.name.hasPrefix("informe (editado en ") && $0.name.hasSuffix(").txt") })
        XCTAssertEqual(try content(of: copy.id), "lo mío")
        XCTAssertEqual(notes.count, 1); XCTAssertTrue(notes[0].contains("cambió en la nube"), notes[0])
        XCTAssertEqual(editing.sessions.first?.file.id, copy.id, "From now on the saves go to the copy")
    }

    func testASaveOfAFileThatIsGoneGoesUpAsANewOne() async throws {
        let file = try remote("borrador.txt", "uno")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        let session = try XCTUnwrap(editing.sessions.first)
        try demo.deletePermanently(file.id)
        try save("dos", to: session)
        await editing.check(session.id)
        try await settle()
        let back = try XCTUnwrap(demo.list("root").first { $0.name == "borrador.txt" })
        XCTAssertEqual(try content(of: back.id), "dos")
        XCTAssertTrue(notes.first?.contains("ya no estaba en la nube") == true)
    }

    func testEndingDeletesTheCopyAndForgetsTheSession() async throws {
        let file = try remote("nota.txt", "hola")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        let session = try XCTUnwrap(editing.sessions.first)
        editing.end(session.id)
        XCTAssertTrue(editing.sessions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.localURL.deletingLastPathComponent().path))
        XCTAssertEqual(try content(of: file.id), "hola", "Ending never touches the remote file")
    }

    func testSessionsSurviveARelaunchAndUploadWhatWasSavedMeanwhile() async throws {
        let file = try remote("nota.txt", "hola")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        let session = try XCTUnwrap(editing.sessions.first)
        try save("guardado con iCloudy cerrado", to: session)

        editing = make()
        XCTAssertEqual(editing.sessions.map(\.id), [session.id])
        editing.start()
        for _ in 0..<200 where queue.items.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        try await settle()
        XCTAssertEqual(try content(of: file.id), "guardado con iCloudy cerrado")
    }

    func testAnUploadThatFailsKeepsTheSaveAndSaysSo() async throws {
        let file = try remote("nota.txt", "hola")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        let session = try XCTUnwrap(editing.sessions.first)
        try save("cambios", to: session)
        await editing.check(session.id)
        let job = try XCTUnwrap(queue.items.first)
        queue.cancel(job.id)
        try await Task.sleep(for: .milliseconds(50))
        let failed = try XCTUnwrap(editing.sessions.first)
        XCTAssertEqual(failed.state, .failed)
        XCTAssertTrue(editing.hasUnsavedChanges(failed.id), "The copy still holds what did not go up")
        XCTAssertEqual(try String(contentsOf: failed.localURL), "cambios")

        editing.uploadNow(failed.id)
        for _ in 0..<200 where queue.items.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        try await settle()
        XCTAssertEqual(try content(of: file.id), "cambios")
        XCTAssertEqual(editing.sessions.first?.state, .watching)
    }

    func testARenameFromTheAppIsFollowed() async throws {
        let file = try remote("nota.txt", "hola")
        try await editing.begin(file, account: .demo, parent: "root", location: "Demo")
        editing.remap(RemoteIdentityChange(oldID: file.id, newID: file.id, name: "apuntes.txt", descendants: false), accountID: Account.demo.id)
        XCTAssertEqual(editing.sessions.first?.file.name, "apuntes.txt")
    }

    func testConflictNamesKeepTheExtension() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let name = EditSessions.conflictName("informe final.docx", host: "MacBook", date: date)
        XCTAssertTrue(name.hasPrefix("informe final (editado en MacBook ")); XCTAssertTrue(name.hasSuffix(").docx"))
        XCTAssertTrue(EditSessions.conflictName("LEEME", host: "Mac", date: date).hasSuffix(")"))
    }

    func testOlderRecordsDecodeAndUnknownStatesWait() throws {
        let json = #"[{"accountID":"a","file":{"id":"f","name":"n.txt","mime":"text/plain","isFolder":false},"parent":"root","localPath":"/tmp/n.txt","state":"algo-nuevo"}]"#
        let decoded = try JSONDecoder().decode([EditSession].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.first?.state, .watching)
    }
}
