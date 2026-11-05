import XCTest
@testable import iCloudy

/// SFTP and FTP write an upload under `.name.icloudy-part` and rename it at the end, so a dropped connection never
/// leaves a truncated file under the real name.
@MainActor
final class PartialUploadTests: XCTestCase {
    private var sshServers: [FakeSSHServer] = []
    override func tearDown() {
        for server in sshServers { server.stop() }
        sshServers = []
        super.tearDown()
    }
    private func source(_ text: String) throws -> (URL, UploadCheckpoint) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("partial-" + UUID().uuidString)
        try Data(text.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, UploadCheckpoint(total: Int64(text.utf8.count), modified: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
    }
    private func sftp(_ configure: (inout FakeSSHServer.Script) -> Void = { _ in }) async throws -> (FakeSSHServer, CloudAPI) {
        var script = FakeSSHServer.Script(); script.sftp = true
        configure(&script)
        let server = try FakeSSHServer(script)
        sshServers.append(server)
        let (account, credential) = try await SFTPAuthentication().signInSFTP(server: "sftp://127.0.0.1:\(server.port)/base", username: "ana",
                                                                              password: "secreta", trustHostKey: { _ in true })
        let store = MemoryCredentials(); store.stored[account.id] = credential
        return (server, CloudAPI(account: account, credentials: store))
    }

    func testThePartialNameIsHiddenBesideTheTarget() {
        XCTAssertEqual(FTPListing.partialName(for: "/base/informe.pdf"), "/base/.informe.pdf.icloudy-part")
        XCTAssertEqual(FTPListing.partialName(for: "/a.txt"), "/.a.txt.icloudy-part")
    }

    func testSFTPUploadsUnderAHiddenNameAndRenamesAtTheEnd() async throws {
        let (server, api) = try await sftp()
        let (local, checkpoint) = try source("contenido")
        let receipt = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil, checkpoint: checkpoint,
                                                    save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "/base/a.txt")
        XCTAssertEqual(server.files, ["/base/a.txt": Data("contenido".utf8)])
        XCTAssertTrue(server.events.contains("sftp:open /base/.a.txt.icloudy-part"), "\(server.events)")
        XCTAssertTrue(server.events.contains("sftp:posix-rename /base/.a.txt.icloudy-part /base/a.txt"))
    }

    func testAFailedSFTPUploadLeavesTheRealFileAlone() async throws {
        let (server, api) = try await sftp { $0.failingWrite = 1 }
        server.files = ["/base/a.txt": Data("antiguo".utf8)]
        let (local, checkpoint) = try source("nuevo")
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: "/base/a.txt", checkpoint: checkpoint,
                                              save: { _ in }, progress: { _, _ in })
            XCTFail("La escritura falla en el servidor")
        } catch {}
        XCTAssertEqual(server.files["/base/a.txt"], Data("antiguo".utf8), "El archivo de verdad no se toca")
        XCTAssertTrue(server.waitFor("sftp:remove /base/.a.txt.icloudy-part"), "El parcial se borra: \(server.events)")
    }

    func testWithoutPosixRenameTheOldFileGoesOnlyOnceTheNewOneIsComplete() async throws {
        let (server, api) = try await sftp { $0.posixRename = false }
        server.files = ["/base/a.txt": Data("antiguo".utf8)]
        let (local, checkpoint) = try source("nuevo")
        _ = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: "/base/a.txt", checkpoint: checkpoint,
                                          save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(server.files, ["/base/a.txt": Data("nuevo".utf8)])
        let order = server.events.filter { $0.hasPrefix("sftp:") }
        XCTAssertEqual(Array(order.suffix(2)), ["sftp:remove /base/a.txt", "sftp:rename /base/.a.txt.icloudy-part /base/a.txt"])
    }

    func testFTPUploadsUnderAHiddenNameAndRenamesAtTheEnd() async throws {
        let server = try FakeFTPServer(files: [:], listings: ["/": ""])
        let port = try await server.start()
        defer { server.stop() }
        let account = Account(id: "ftp:parcial", cloud: .ftp, name: "Test", email: "ana@test", clientID: "", clientSecret: nil,
                              serverURL: "ftp://127.0.0.1:\(port)/")
        let api = CloudAPI(account: account, tokenProvider: { Data("ana:secreta".utf8).base64EncodedString() })
        let (local, checkpoint) = try source("contenido")
        let receipt = try await api.resumableUpload(local: local, parent: "root", name: "s.txt", replacing: nil, checkpoint: checkpoint,
                                                    save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "/s.txt")
        XCTAssertEqual(server.uploaded(), ["/s.txt": Data("contenido".utf8)])
        let log = server.log()
        XCTAssertTrue(log.contains("STOR /.s.txt.icloudy-part"), "\(log)")
        XCTAssertEqual(Array(log.suffix(2)), ["RNFR /.s.txt.icloudy-part", "RNTO /s.txt"])
    }
}
