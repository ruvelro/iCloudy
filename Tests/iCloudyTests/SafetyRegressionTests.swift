import XCTest
import Network
@testable import iCloudy

/// Regression coverage for the P1 findings in the September audit.
@MainActor
final class SafetyRegressionTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CloudError.message("Audit probe timed out")
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testMirrorCopyThenEditPreservesTheStrangersFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let source = local.appendingPathComponent("a.txt")
        try Data("mine".utf8).write(to: source)
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let remoteID = try demo.add(name: "Destination", parent: "root", folder: true)
        let original = try demo.add(name: "a.txt", parent: remoteID, content: Data("stranger".utf8))
        let folder = try XCTUnwrap(demo.list("root").first { $0.id == remoteID })
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false; manager.queue = queue
        queue.didFinish = { manager.handleFinished($0) }
        try manager.add(local: local, account: .demo, folder: folder, path: [])
        try await wait { queue.conflict != nil }
        queue.resolve(.copy, applyToBatch: false)
        try await wait { manager.mirrors.first?.lastSync != nil }
        let previous = manager.mirrors[0].lastSync
        try Data("mine updated".utf8).write(to: source)
        manager.syncNow(manager.mirrors[0].id)
        try await wait { manager.mirrors.first?.lastSync != previous }
        XCTAssertNil(queue.conflict)
        XCTAssertEqual(try String(contentsOf: demo.directory.appendingPathComponent(original)), "stranger")
        let copy = try XCTUnwrap(demo.list(remoteID).first { $0.name == "a (2).txt" })
        XCTAssertEqual(try String(contentsOf: demo.directory.appendingPathComponent(copy.id)), "mine updated")
    }
    func testFTPTimeoutReleasesPendingReceive() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in connection.cancel() }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let ftp = FTPSession(host: "127.0.0.1", port: listener.port!.rawValue, user: "fake", password: "fake", security: .none)
        await ftp.setTimeout(0.05)
        var finished = false
        let task = Task { _ = try? await ftp.connect(); finished = true }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(finished, "The 50 ms timeout must release the receive without an external close")
        await ftp.close()
        await task.value
    }
    func testFTPCancellationReleasesPendingReceive() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { _, _, _, _ in connection.cancel() }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                if case .ready = state { continuation.resume() }
                if case .failed(let error) = state { continuation.resume(throwing: error) }
            }
            listener.start(queue: .global())
        }
        defer { listener.cancel() }
        let ftp = FTPSession(host: "127.0.0.1", port: listener.port!.rawValue, user: "fake", password: "fake", security: .none)
        await ftp.setTimeout(60)
        var finished = false
        let task = Task {
            do { try await ftp.connect(); XCTFail("Cancelled connect must throw") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            finished = true
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(finished, "Cancellation must release the receive immediately, even with a 60 second timeout")
        await ftp.close()
        await task.value
    }
    func testRedirectGuardRemovesAuthorizationOnDifferentPort() async throws {
        var original = URLRequest(url: URL(string: "https://example.com:443/a")!)
        original.setValue("Basic FAKE", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        var next = original; next.url = URL(string: "https://example.com:8443/b")!
        let result = await RedirectGuard.shared.urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: next)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.value(forHTTPHeaderField: "Authorization"))
    }
    func testVolumeRejectsSymlinkedAncestorOutsideRoot() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("private.txt"))
        let link = inside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let account = Account(id: "audit-volume", cloud: .volume, name: "audit", email: "audit", clientID: "", clientSecret: nil, serverURL: inside.path)
        let api = CloudAPI(account: account)
        XCTAssertThrowsError(try (api.provider as! VolumeProvider).volumeURL(link.appendingPathComponent("private.txt").path))
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("private.txt")), "outside")
    }
    func testBoxChecksumFailureRemainsFailureAfterRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root); StubProtocol.handler = nil }
        let local = root.appendingPathComponent("a.txt"); try Data("correct".utf8).write(to: local)
        let account = Account(id: "audit-box", cloud: .box, name: "audit", email: "audit", clientID: "", clientSecret: nil)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "fake" })
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (201, [:], Data(#"{"entries":[{"id":"123","sha1":"wrong"}]}"#.utf8)) }
        var checkpoint: UploadCheckpoint?
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil,
                checkpoint: nil, save: { checkpoint = $0 }, progress: { _, _ in })
            XCTFail("Expected checksum rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verificación")) }
        XCTAssertEqual(checkpoint?.complete, true)
        XCTAssertEqual(checkpoint?.integrity, .failed)
        let restored = try JSONDecoder().decode(UploadCheckpoint.self, from: JSONEncoder().encode(XCTUnwrap(checkpoint)))
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil,
                checkpoint: restored, save: { checkpoint = $0 }, progress: { _, _ in })
            XCTFail("A known corrupt remote copy must never turn into success")
        } catch {}
        XCTAssertEqual(calls, 1)
    }

    func testDropboxRejectsSourceMutationBetweenBlocks() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root); StubProtocol.handler = nil }
        let local = root.appendingPathComponent("a.dat")
        let count = Int(DropboxProvider.dropboxChunk)
        try Data(repeating: 65, count: count + 8).write(to: local)
        let account = Account(id: "audit-dropbox", cloud: .dropbox, name: "audit", email: "audit", clientID: "", clientSecret: nil)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "fake" })
        var blocks = 0, sent = Data()
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/start") { return (200, [:], Data(#"{"session_id":"fake"}"#.utf8)) }
            if request.url!.path.hasSuffix("/append_v2") {
                blocks += 1; sent.append(requestData(request))
                if blocks == 1 {
                    let file = try FileHandle(forWritingTo: local); defer { try? file.close() }
                    try file.seek(toOffset: 0); try file.write(contentsOf: Data(repeating: 66, count: count + 8))
                }
                return (200, [:], Data())
            }
            var hash = DropboxContentHash(); hash.update(sent)
            return (200, [:], try JSONSerialization.data(withJSONObject: ["path_lower": "/a.dat", "content_hash": hash.finalize()]))
        }
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "a.dat", replacing: nil,
                checkpoint: nil, save: { _ in }, progress: { _, _ in })
            XCTFail("Changing the source must stop the upload")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cambió"), error.localizedDescription) }
        XCTAssertEqual(blocks, 1, "Neither the mutated second block nor finish may be sent")
        XCTAssertEqual(sent.count, count)
    }
    func testDropboxFailedAndPendingIntegrityCannotBecomeSuccessOnRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root); StubProtocol.handler = nil }
        let local = root.appendingPathComponent("a.txt"); try Data("correct".utf8).write(to: local)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test", cloud: .dropbox, name: "test", email: "test", clientID: "", clientSecret: nil)
        let api = CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "fake" })
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            if request.url!.path.hasSuffix("/start") { return (200, [:], Data(#"{"session_id":"s"}"#.utf8)) }
            if request.url!.path.hasSuffix("/append_v2") { return (200, [:], Data()) }
            return (200, [:], Data(#"{"path_lower":"/a.txt","content_hash":"wrong"}"#.utf8))
        }
        var saved: UploadCheckpoint?
        do {
            _ = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil,
                checkpoint: nil, save: { saved = $0 }, progress: { _, _ in })
            XCTFail("Wrong hash must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("verificación")) }
        XCTAssertEqual(saved?.integrity, .failed)
        XCTAssertEqual(saved?.remoteID, "/a.txt")
        let before = calls
        for state: UploadIntegrity? in [.failed, .pending, nil] {
            var checkpoint = try XCTUnwrap(saved); checkpoint.integrity = state
            let restored = try JSONDecoder().decode(UploadCheckpoint.self, from: JSONEncoder().encode(checkpoint))
            do {
                _ = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil,
                    checkpoint: restored, save: { _ in }, progress: { _, _ in })
                XCTFail("A failed, interrupted or legacy unverified commit requires explicit recovery")
            } catch {}
        }
        XCTAssertEqual(calls, before)
    }
    func testVerifiedCheckpointKeepsRemoteIdentityOnResume() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("a.txt"); try Data("abc".utf8).write(to: local)
        let modified = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var checkpoint = UploadCheckpoint(total: 3, modified: modified, complete: true)
        checkpoint.integrity = .verified; checkpoint.remoteID = "owned-id"; checkpoint.sourceStamp = try UploadSourceStamp(local)
        let restored = try JSONDecoder().decode(UploadCheckpoint.self, from: JSONEncoder().encode(checkpoint))
        let api = CloudAPI(account: Account(id: "b", cloud: .box, name: "", email: "", clientID: "", clientSecret: nil))
        let result = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil,
            checkpoint: restored, save: { _ in XCTFail("No new checkpoint or network needed") }, progress: { _, _ in })
        XCTAssertEqual(result.remoteID, "owned-id"); XCTAssertEqual(result.verification, .verified)
    }
    func testSourceStampDetectsSameSizeEditWithRestoredModificationTime() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("a"); try Data("abc".utf8).write(to: local)
        let date = try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        let stamp = try UploadSourceStamp(local)
        try Data("def".utf8).write(to: local)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: local.path)
        XCTAssertThrowsError(try stamp.validate(local))
    }
    func testVolumeMutationsRejectSymlinkAncestorsAndDanglingDestinations() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protected = outside.appendingPathComponent("private.txt")
        try Data("original".utf8).write(to: protected)
        let link = inside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let api = CloudAPI(account: Account(id: "v", cloud: .volume, name: "", email: "", clientID: "", clientSecret: nil, serverURL: inside.path))
        let file = CloudFile(id: link.appendingPathComponent("private.txt").path, name: "private.txt", mime: "text/plain", size: 8, modified: nil, webURL: nil, isFolder: false)
        do { _ = try await (api.provider as! VolumeProvider).volumeList(parent: link.path); XCTFail() } catch {}
        do { _ = try await (api.provider as! VolumeProvider).volumeCreateFolder(name: "new", parent: link.path); XCTFail() } catch {}
        do { try await (api.provider as! VolumeProvider).volumeRename(file: file, name: "renamed"); XCTFail() } catch {}
        do { try await (api.provider as! VolumeProvider).volumeTrash(file: file); XCTFail() } catch {}
        do { try await (api.provider as! VolumeProvider).volumeMove(file: file, to: "root"); XCTFail() } catch {}
        do { try await (api.provider as! VolumeProvider).volumeCopy(file: file, to: "root"); XCTFail() } catch {}
        do { try await (api.provider as! VolumeProvider).volumeDownload(file: file, to: root.appendingPathComponent("download"), progress: { _, _ in }); XCTFail() } catch {}
        let dangling = inside.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: outside.appendingPathComponent("missing"))
        do {
            _ = try await api.resumableUpload(local: protected, parent: "root", name: "dangling", replacing: nil,
                checkpoint: nil, save: { _ in }, progress: { _, _ in })
            XCTFail()
        } catch {}
        XCTAssertEqual(try String(contentsOf: protected), "original")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["private.txt"])
    }
    func testPinnedVolumePathCannotBeRedirectedByReplacingItsAncestor() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("dir"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("target"))
        let path = try VolumePath(root: root, url: directory.appendingPathComponent("target"))
        try FileManager.default.moveItem(at: directory, to: root.appendingPathComponent("old"))
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside)
        let output = try path.openFile(O_WRONLY | O_CREAT | O_EXCL)
        try output.write(contentsOf: Data("inside".utf8)); try output.close()
        XCTAssertEqual(try String(contentsOf: outside.appendingPathComponent("target")), "outside")
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("old/target")), "inside")
    }
    func testFTPDataTimeoutAndCancellationCannotTurnIntoSuccessfulEOF() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        for cancel in [false, true] {
            let server = try FakeFTPServer(files: ["/a": Data("payload".utf8)], listings: [:], stallRetrievals: true)
            let port = try await server.start()
            defer { server.stop() }
            let ftp = FTPSession(host: "127.0.0.1", port: port, user: "test", password: "secreta", security: .none)
            await ftp.setTimeout(cancel ? 60 : 0.1)
            let output = root.appendingPathComponent(UUID().uuidString)
            var finished = false
            let task = Task {
                do { try await ftp.retrieve(path: "/a", to: output, progress: { _ in }); XCTFail("A stalled stream is not EOF") }
                catch {
                    if cancel { XCTAssertTrue(error is CancellationError, "\(error)") }
                    else { XCTAssertTrue(error.localizedDescription.contains("tiempo"), error.localizedDescription) }
                }
                finished = true
            }
            try await wait { server.log().contains("RETR /a") }
            if cancel { task.cancel() }
            try await Task.sleep(for: .milliseconds(350))
            XCTAssertTrue(finished, "The data-channel operation must release without an external close")
            await ftp.close(); await task.value
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "No partial file survives the failed receive")
        }
    }
}
