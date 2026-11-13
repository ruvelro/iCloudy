import XCTest
@testable import iCloudy

/// SFTP uploads and downloads that carry on from an offset after a failure, against the in-process SSH server.
@MainActor
final class SFTPResumeTests: XCTestCase {
    private var servers: [FakeSSHServer] = []
    override func tearDown() {
        for server in servers { server.stop() }
        servers = []
        super.tearDown()
    }
    private func sftp(_ configure: (inout FakeSSHServer.Script) -> Void = { _ in }) async throws -> (FakeSSHServer, CloudAPI) {
        var script = FakeSSHServer.Script(); script.sftp = true
        configure(&script)
        let server = try FakeSSHServer(script)
        servers.append(server)
        let (account, credential) = try await SFTPAuthentication().signInSFTP(server: "sftp://127.0.0.1:\(server.port)/base", username: "ana",
                                                                              password: "secreta", trustHostKey: { _ in true })
        let store = MemoryCredentials(); store.stored[account.id] = credential
        return (server, CloudAPI(account: account, credentials: store))
    }
    private func payload(blocks: Int) -> Data {
        Data((0..<(blocks * SFTPClient.blockSize)).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 977) })
    }

    func testAnInterruptedUploadContinuesFromTheConfirmedOffset() async throws {
        // The third WRITE fails: with one block per segment, two segments are confirmed and checkpointed.
        let (server, api) = try await sftp { $0.failingWrite = 3 }
        (api.provider as! SFTPProvider).uploadSegment = Int64(SFTPClient.blockSize)
        let data = payload(blocks: 5)
        let local = try temporaryRoot().appendingPathComponent("grande.bin")
        try data.write(to: local)
        var saved: UploadCheckpoint?
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "grande.bin", replacing: nil, checkpoint: nil,
                                              save: { saved = $0 }, progress: { _, _ in })
            XCTFail("The third write is refused")
        } catch {}
        XCTAssertEqual(saved?.offset, Int64(2 * SFTPClient.blockSize), "Two segments were confirmed")
        XCTAssertEqual(saved?.sessionID, "/base/.grande.bin.icloudy-part")
        XCTAssertEqual(server.files["/base/.grande.bin.icloudy-part"]?.count, 2 * SFTPClient.blockSize, "The partial stays for the retry")

        let opensBefore = server.events.filter { $0 == "sftp:open /base/.grande.bin.icloudy-part" }.count
        let receipt = try await api.resumableUpload(local: local, parent: "root", name: "grande.bin", replacing: nil, checkpoint: saved,
                                                    save: { saved = $0 }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "/base/grande.bin")
        XCTAssertEqual(server.files["/base/grande.bin"], data, "The resumed file is the whole source, in order")
        XCTAssertNil(server.files["/base/.grande.bin.icloudy-part"])
        XCTAssertEqual(server.events.filter { $0 == "sftp:open /base/.grande.bin.icloudy-part" }.count - opensBefore, 3,
                       "The retry sent only the three remaining segments")
        XCTAssertEqual(saved?.complete, true)
    }

    func testAChangedSourceIsNotStitchedToTheOldPartial() async throws {
        let (_, api) = try await sftp { $0.failingWrite = 2 }
        (api.provider as! SFTPProvider).uploadSegment = Int64(SFTPClient.blockSize)
        let local = try temporaryRoot().appendingPathComponent("a.bin")
        try payload(blocks: 3).write(to: local)
        var saved: UploadCheckpoint?
        do { _ = try await api.resumableUpload(local: local, parent: "root", name: "a.bin", replacing: nil, checkpoint: nil, save: { saved = $0 }, progress: { _, _ in }) }
        catch {}
        XCTAssertEqual(saved?.offset, Int64(SFTPClient.blockSize))
        try payload(blocks: 4).write(to: local)
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "a.bin", replacing: nil, checkpoint: saved, save: { _ in }, progress: { _, _ in })
            XCTFail("A source that changed after bytes were sent must not be resumed")
        } catch { XCTAssertTrue(error is UploadSourceChanged, "\(error)") }
    }

    func testCancellingAnUploadRemovesItsPartialAndNothingElse() async throws {
        let (server, api) = try await sftp()
        server.files = ["/base/.a.bin.icloudy-part": Data("x".utf8), "/base/a.bin": Data("y".utf8)]
        await api.abandonUploadSessions(urls: [], sessionIDs: ["/base/.a.bin.icloudy-part", "/base/a.bin"])
        XCTAssertEqual(server.files, ["/base/a.bin": Data("y".utf8)])
    }

    func testADownloadContinuesAPartialOfTheSameVersionAndRestartsAnyOther() async throws {
        let (server, api) = try await sftp()
        let data = payload(blocks: 3)
        server.files = ["/base/big.bin": data]
        let folder = try temporaryRoot()
        let partial = folder.appendingPathComponent(ResumableDownload.partialName(job: UUID(), key: "./big.bin"))
        XCTAssertTrue(ResumableDownload.isPartial(partial))
        let file = CloudFile(id: "/base/big.bin", name: "big.bin", mime: "application/octet-stream", size: Int64(data.count),
                             modified: Date(timeIntervalSince1970: 1_700_000_000), webURL: nil, isFolder: false)
        // A first attempt that got one block and a half: the stamp, then the bytes appended to the same file.
        func append(_ bytes: Data) throws {
            let handle = try FileHandle(forWritingTo: partial)
            try handle.seekToEnd(); try handle.write(contentsOf: bytes); try handle.close()
        }
        XCTAssertEqual(try ResumableDownload.prepare(partial, for: file), 0)
        try append(data.prefix(SFTPClient.blockSize * 3 / 2))
        XCTAssertEqual(try ResumableDownload.prepare(partial, for: file), Int64(SFTPClient.blockSize * 3 / 2), "The same version resumes")
        _ = try await api.download(file: file, to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), data)
        XCTAssertEqual(server.events.first { $0.hasPrefix("sftp:read") }, "sftp:read \(SFTPClient.blockSize * 3 / 2)", "Reading started where the partial ended")

        // The same partial name with another version listed: everything is fetched again.
        try FileManager.default.removeItem(at: partial)
        _ = try ResumableDownload.prepare(partial, for: file)
        try append(data.prefix(100))
        let changed = CloudFile(id: file.id, name: file.name, mime: file.mime, size: file.size,
                                modified: Date(timeIntervalSince1970: 1_800_000_000), webURL: nil, isFolder: false)
        let readsBefore = server.events.filter { $0 == "sftp:read 0" }.count
        _ = try await api.download(file: changed, to: partial)
        XCTAssertEqual(try Data(contentsOf: partial), data)
        XCTAssertEqual(server.events.filter { $0 == "sftp:read 0" }.count, readsBefore + 1, "Another version starts from zero")
    }

    func testThePartialsOfACancelledJobAreRemoved() throws {
        let folder = try temporaryRoot()
        let job = UUID(), other = UUID()
        let mine = folder.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        let a = mine.appendingPathComponent(ResumableDownload.partialName(job: job, key: "./sub/a"))
        let b = folder.appendingPathComponent(ResumableDownload.partialName(job: other, key: "./b"))
        try Data().write(to: a); try Data().write(to: b)
        ResumableDownload.removePartials(job: job, under: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path), "Another job's partial is not touched")
        XCTAssertTrue(Cloud.sftp.capabilities.resumesDownloads && Cloud.sftp.capabilities.chunkedUploads, "SFTP declares both kinds of resume")
    }
}
