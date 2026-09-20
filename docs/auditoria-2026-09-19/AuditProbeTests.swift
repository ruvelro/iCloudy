import XCTest
import Network
@testable import iCloudy

/// Audit probes assert the observed defect, not the desired corrected behavior.
@MainActor
final class AuditProbeTests: XCTestCase {
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw CloudError.message("Audit probe timed out")
    }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-audit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func testMirrorCopyThenEditOverwritesTheOriginalStrangersFile() async throws {
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
        XCTAssertEqual(try String(contentsOf: demo.directory.appendingPathComponent(original)), "mine updated")
        let copy = try XCTUnwrap(demo.list(remoteID).first { $0.name == "a (2).txt" })
        XCTAssertEqual(try String(contentsOf: demo.directory.appendingPathComponent(copy.id)), "mine")
    }
    func testO2PersistDropsSavedSSOCookies() throws {
        let store = MemoryCredentials()
        let account = Account(id: "audit-o2", cloud: .o2, name: "audit", email: "audit", clientID: "", clientSecret: nil)
        let cookie = HTTPCookie(properties: [.name: "SSOSESSION", .value: "fake", .domain: "t3.o2online.es", .path: "/"])!
        store.stored[account.id] = Credential(accessToken: "", refreshToken: "", expires: .distantFuture,
            secret: O2API.store(validationKey: "before", cookies: [], sso: [cookie]))
        let api = CloudAPI(account: account, credentials: store)
        let state = try api.o2Session(); state.renewed = true; state.validationKey = "after"
        api.o2Persist(state)
        XCTAssertTrue(O2API.restoreSSO(store.stored[account.id]!.secret).isEmpty)
    }
    func testO2DownloadIgnoresAuthorizedByteLimit() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root); StubProtocol.handler = nil }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "audit-o2", cloud: .o2, name: "audit", email: "audit", clientID: "", clientSecret: nil)
        let store = MemoryCredentials()
        store.stored[account.id] = Credential(accessToken: "", refreshToken: "", expires: .distantFuture,
            secret: O2API.store(validationKey: "fake", cookies: []))
        StubProtocol.handler = { request in
            if request.url?.host == "download.example.com" { return (200, [:], Data(repeating: 65, count: 100)) }
            return (200, [:], Data(#"{"data":{"media":[{"url":"https://download.example.com/file"}]}}"#.utf8))
        }
        let api = CloudAPI(account: account, session: URLSession(configuration: config), credentials: store)
        let file = CloudFile(id: "m:file:1", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        let output = root.appendingPathComponent("download")
        try await api.download(file: file, to: output, maxBytes: 1)
        XCTAssertEqual(try Data(contentsOf: output).count, 100)
    }
    func testFTPTimeoutDoesNotReleasePendingReceive() async throws {
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
        XCTAssertFalse(finished, "The 50 ms timeout is still stuck after 400 ms")
        await ftp.close()
        await task.value
    }
    func testCrossCloudCancelLooksUpSourceInsteadOfDestination() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.setOnline(false)
        var lookedUp: [String] = []
        queue.client = { id in lookedUp.append(id); throw CancellationError() }
        var transfer = Transfer(name: "a", destination: "target", accountID: "source", direction: .transfer, localURL: root.appendingPathComponent("scratch"))
        transfer.targetAccountID = "target"
        transfer.uploads["."] = UploadCheckpoint(total: 1, sessionID: "fake-box-session")
        try queue.add([transfer]); queue.cancel(transfer.id)
        XCTAssertEqual(lookedUp, ["source"])
    }
    func testRedirectGuardRetainsAuthorizationOnDifferentPort() async throws {
        var original = URLRequest(url: URL(string: "https://example.com:443/a")!)
        original.setValue("Basic FAKE", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: original)
        var next = original; next.url = URL(string: "https://example.com:8443/b")!
        let result = await RedirectGuard.shared.urlSession(session, task: task,
            willPerformHTTPRedirection: HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!, newRequest: next)
        XCTAssertEqual(result?.value(forHTTPHeaderField: "Authorization"), "Basic FAKE")
    }
    func testVolumeAcceptsSymlinkedAncestorOutsideRoot() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside"), outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside".utf8).write(to: outside.appendingPathComponent("private.txt"))
        let link = inside.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let account = Account(id: "audit-volume", cloud: .volume, name: "audit", email: "audit", clientID: "", clientSecret: nil, serverURL: inside.path)
        let api = CloudAPI(account: account)
        let target = try api.volumeURL(link.appendingPathComponent("private.txt").path)
        XCTAssertEqual(try String(contentsOf: target), "outside")
    }
    func testBoxChecksumFailureBecomesSuccessOnRetryWithoutVerification() async throws {
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
        let retried = try await api.resumableUpload(local: local, parent: "root", name: "a.txt", replacing: nil,
            checkpoint: checkpoint, save: { checkpoint = $0 }, progress: { _, _ in })
        XCTAssertEqual(retried.verification, .unavailable)
        XCTAssertEqual(calls, 1, "Retry neither retransmits nor verifies the corrupt remote copy")
    }
    func testDropboxDoesNotRejectSourceMutationBetweenBlocks() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root); StubProtocol.handler = nil }
        let local = root.appendingPathComponent("a.dat")
        let count = Int(CloudAPI.dropboxChunk)
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
        let receipt = try await api.resumableUpload(local: local, parent: "root", name: "a.dat", replacing: nil,
            checkpoint: nil, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertEqual(sent.prefix(8), Data(repeating: 65, count: 8))
        XCTAssertEqual(sent.suffix(8), Data(repeating: 66, count: 8))
        XCTAssertNotEqual(sent, try Data(contentsOf: local))
    }
}
