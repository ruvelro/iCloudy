import XCTest
@testable import iCloudy

@MainActor
final class P2RegressionTests: XCTestCase {
    func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("icloudy-p2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func file(_ id: String = "/a", folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: "a", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: folder)
    }
    func api(_ cloud: Cloud, credentials: MemoryCredentials = MemoryCredentials()) -> CloudAPI {
        let account = Account(id: cloud.rawValue + ":p2", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil)
        credentials.stored[account.id] = credentials.stored[account.id] ?? Credential(accessToken: "token", refreshToken: "refresh", expires: .distantFuture)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: account, session: URLSession(configuration: configuration), credentials: credentials)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Timed out")
    }
    func testO2RenewalPreservesSSOAndRetriesFailedPersistence() throws {
        let store = MemoryCredentials(), client = api(.o2)
        let account = client.account
        let sso = try XCTUnwrap(HTTPCookie(properties: [.name: "sso", .value: "keep", .domain: "login.example.com", .path: "/"]))
        store.stored[account.id] = Credential(accessToken: "", refreshToken: "", expires: .distantFuture, secret: O2API.store(validationKey: "old", cookies: [], sso: [sso]))
        let real = CloudAPI(account: account, credentials: store)
        let state = O2Session(host: "cloud.o2online.es", validationKey: "new"); state.renewed = true
        var reported = false; real.credentialSaveDidFail = { _ in reported = true }
        store.refuseSaves = true; real.o2Persist(state)
        XCTAssertTrue(state.renewed); XCTAssertTrue(reported)
        store.refuseSaves = false; real.o2Persist(state)
        XCTAssertFalse(state.renewed)
        XCTAssertEqual(O2API.restoreSSO(try XCTUnwrap(store.stored[account.id]).secret).first?.value, "keep")
        XCTAssertEqual(O2API.restore(try XCTUnwrap(store.stored[account.id]).secret)?.validationKey, "new")
    }
    func testFTPPortBoundariesAreValidatedWithoutTrapping() throws {
        for port in [0, 65536, 999999] { XCTAssertThrowsError(try CloudAPI.ftpEndpoint("ftp://example.com:\(port)")) }
        XCTAssertEqual(try CloudAPI.ftpEndpoint("ftp://example.com:65535").port, 65535)
        XCTAssertEqual(try CloudAPI.ftpEndpoint("ftps://example.com").port, 990)
    }
    func testVolumeBudgetRefusesBeforeCreatingDestination() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("destination")
        try Data(repeating: 1, count: 100).write(to: source)
        do { try await CloudAPI.volumeCopyContents(from: source, to: destination, maxBytes: 10) { _, _ in }; XCTFail("Expected limit") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testFTPBudgetStopsAndRemovesPartialFile() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let server = try FakeFTPServer(files: ["/a": Data(repeating: 1, count: 100_000)], listings: ["/": ""])
        let port = try await server.start(); defer { server.stop() }
        let ftp = FTPSession(host: "127.0.0.1", port: port, user: "test", password: "test", security: .none)
        let destination = root.appendingPathComponent("out")
        do { try await ftp.retrieve(path: "/a", to: destination, maxBytes: 10) { _ in }; XCTFail("Expected limit") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await ftp.close()
    }
    func testO2UnknownSizeStillHonorsDownloadBudget() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = api(.o2)
        client.o2SessionCache = O2Session(host: "cloud.o2online.es", validationKey: "key")
        StubProtocol.handler = { request in
            if request.url?.path == "/sapi/media" { return (200, [:], Data(#"{"data":{"media":[{"url":"https://cloud.o2online.es/file"}]}}"#.utf8)) }
            return (200, [:], Data(repeating: 1, count: 100))
        }
        let destination = root.appendingPathComponent("out")
        do { try await client.download(file: file("m:file:1"), to: destination, maxBytes: 10); XCTFail("Expected limit") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
    func testCacheDisableDrainsWritesAndClearsMemoryAndDisk() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ListingCache(directory: root)
        cache.store([file()], accountID: "a", parent: "root")
        cache.enabled = false
        cache.store([file("/b")], accountID: "a", parent: "root")
        await cache.settle()
        XCTAssertNil(cache.cached(accountID: "a", parent: "root"))
        XCTAssertNil(ListingCache(directory: root).cached(accountID: "a", parent: "root"))
        cache.enabled = true
        XCTAssertNil(cache.cached(accountID: "a", parent: "root"))
    }
    func testCacheHasGlobalEntryAndByteBudgets() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ListingCache(directory: root); cache.maxTotalItems = 2; cache.maxListings = 2
        for n in 0..<5 { cache.store([file("/\(n)")], accountID: "a", parent: "\(n)") }
        await cache.settle()
        XCTAssertLessThanOrEqual((0..<5).compactMap { cache.cached(accountID: "a", parent: "\($0)") }.count, 2)
        let restored = ListingCache(directory: root)
        XCTAssertLessThanOrEqual((0..<5).compactMap { restored.cached(accountID: "a", parent: "\($0)") }.count, 2)
        cache.maxBytes = 1; cache.store([file()], accountID: "b", parent: "root"); await cache.settle()
        XCTAssertNil(cache.cached(accountID: "b", parent: "root"))
    }
    func testCacheExpiredListingsAreNotRead() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = ListingCache(directory: root); cache.store([file()], accountID: "a", parent: "root"); await cache.settle()
        cache.maxAge = -1
        XCTAssertNil(cache.cached(accountID: "a", parent: "root"))
    }
    func testIdentityChangeRemapsDescendantsWithoutMatchingSiblings() throws {
        let change = RemoteIdentityChange(oldID: "/a", newID: "/renamed", name: "renamed", descendants: true)
        XCTAssertEqual(change.id("/a/child"), "/renamed/child")
        XCTAssertEqual(change.id("/another/child"), "/another/child")
        XCTAssertEqual(change.file(file()).name, "renamed")
        XCTAssertEqual(try api(.dropbox).identityChange(file: file("/old"), name: "NEW").newID, "/new")
        XCTAssertEqual(try api(.webdav).identityChange(file: file("/old/"), name: "NEW").newID, "/NEW")
    }
    func testPendingQueueAndLocalCopiesRemapAndSurviveReload() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.setOnline(false)
        var transfer = Transfer(name: "a", destination: "a", accountID: "account", direction: .download, localURL: root, file: file("/a/child"))
        transfer.state = .paused
        try queue.add([transfer])
        let change = RemoteIdentityChange(oldID: "/a", newID: "/b", name: "b", descendants: true)
        try queue.remap(change, accountID: "account")
        XCTAssertEqual(TransferQueue(storeURL: queue.storeURL).items.first?.file?.id, "/b/child")
        let copies = LocalCopyIndex(storeURL: root.appendingPathComponent("copies.json"))
        copies.record(LocalCopy(accountID: "account", fileID: "/a/child", name: "child", path: root.path, size: 1, savedAt: Date(), origin: .download))
        copies.remap(change, accountID: "account")
        XCTAssertEqual(LocalCopyIndex(storeURL: copies.storeURL).copies.values.first?.fileID, "/b/child")
    }
    func testUnavailableBookmarkAndUnmountedVolumeAreRetained() {
        for path in ["/Volumes/missing-p2/a", "/tmp/unknown-p2/a"] {
            let copy = LocalCopy(accountID: "a", fileID: "f", name: "a", path: path, bookmark: Data([0]), size: 1, savedAt: Date(), origin: .download)
            guard case .unavailable = LocalCopyIndex.resolve(copy) else { return XCTFail("Unavailable is not deleted") }
        }
    }
    func testFileBookmarkResolvesMovedFile() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original"), moved = root.appendingPathComponent("moved")
        try Data([1]).write(to: original)
        let bookmark = try TransferQueue.bookmark(original)
        let copy = LocalCopy(accountID: "a", fileID: "f", name: "a", path: original.path, bookmark: bookmark, size: 1, savedAt: Date(), origin: .download)
        try FileManager.default.moveItem(at: original, to: moved)
        guard case .available(let updated) = LocalCopyIndex.resolve(copy) else { return XCTFail("Bookmark must track the move") }
        XCTAssertEqual(updated.url.resolvingSymlinksInPath(), moved.resolvingSymlinksInPath())
    }
    func testNewEmptyDirectoryReopensAncestors() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
        let previous = try MirrorPlanner.stamps(of: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("folder/empty"), withIntermediateDirectories: true)
        let current = try MirrorPlanner.stamps(of: root)
        XCTAssertNotNil(current["folder/empty"])
        XCTAssertFalse(MirrorPlanner.completedKeys(current: current, previous: previous).contains("./folder"))
    }
    func testRemoteCopyTracksCompletionWithoutRepeatingPostAfterRestart() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let client = api(.microsoft), queue = RemoteCopies(storeURL: root.appendingPathComponent("copies.json"))
        var posts = 0, polls = 0
        StubProtocol.handler = { request in
            if request.httpMethod == "POST" { posts += 1; return (202, ["Location": "https://graph.microsoft.com/monitor/1"], Data()) }
            polls += 1
            return (200, [:], Data(#"{"status":"completed"}"#.utf8))
        }
        // No client callback: receipt is persisted, but this instance cannot poll it.
        try await queue.start(file: file("f"), destination: "dest", api: client)
        XCTAssertEqual(queue.items.first?.state, .monitoring)
        let restored = RemoteCopies(storeURL: queue.storeURL)
        restored.client = { _ in client }; restored.resume()
        try await wait { restored.items.first?.state == .completed }
        XCTAssertEqual(posts, 1); XCTAssertEqual(polls, 1)
        XCTAssertEqual(RemoteCopies(storeURL: queue.storeURL).items.first?.state, .completed)
    }
    func testRemoteCopyFailureIsNotReportedAsSuccess() async throws {
        let client = api(.microsoft)
        StubProtocol.handler = { _ in (200, [:], Data(#"{"status":"failed","error":{"code":"nameAlreadyExists"}}"#.utf8)) }
        let status = try await client.remoteCopyStatus(URL(string: "https://graph.microsoft.com/monitor/1")!)
        XCTAssertEqual(status, .failed)
        XCTAssertFalse(CloudAPI.validCopyMonitor(URL(string: "https://graph.microsoft.com.evil.example/monitor")!))
        XCTAssertFalse(CloudAPI.validCopyMonitor(URL(string: "http://graph.microsoft.com/monitor")!))
    }
    func testCrossCloudCompletedCheckpointDoesNotDownloadOrUploadAgain() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let demo = try DemoStore(directory: root.appendingPathComponent("cloud")); demo.latency = .milliseconds(1)
        let sourceID = try demo.add(name: "original", parent: "root", content: Data([1]))
        let source = try XCTUnwrap(demo.list("root").first { $0.id == sourceID })
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        queue.client = { _ in CloudAPI(account: .demo, demo: demo) }
        var notifications: [String] = []; queue.didComplete = { notifications.append($0) }
        var transfer = Transfer(name: source.name, destination: "dest", accountID: "source", direction: .transfer, localURL: root.appendingPathComponent("missing"), file: source)
        transfer.targetAccountID = "target"; transfer.names["."] = "copy"
        transfer.uploads["."] = UploadCheckpoint(total: 1, complete: true, integrity: .verified, remoteID: "existing-copy")
        try queue.add([transfer])
        try await wait { queue.items.first?.state == .completed }
        XCTAssertEqual(try demo.list("root").filter { $0.name == "copy" }.count, 0)
        XCTAssertEqual(Set(notifications), ["source", "target"])
    }
    func testCancelAbandonsSessionsOnDestinationAccount() throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.setOnline(false)
        var lookedUp: [String] = []
        queue.client = { id in lookedUp.append(id); return self.api(.microsoft) }
        var transfer = Transfer(name: "a", destination: "dest", accountID: "source", direction: .transfer, localURL: root.appendingPathComponent("scratch"))
        transfer.targetAccountID = "target"
        transfer.uploads["."] = UploadCheckpoint(url: URL(string: "https://storage.example.com/session"))
        StubProtocol.handler = { _ in (204, [:], Data()) }
        try queue.add([transfer]); queue.cancel(transfer.id)
        XCTAssertEqual(lookedUp, ["target"])
    }
    func testRemovingMirrorCancelsItsQueuedTransfer() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("local")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json")); queue.setOnline(false)
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json")); manager.watching = false; manager.queue = queue
        try manager.add(local: local, account: .demo, folder: file("remote", folder: true), path: [])
        try await wait { manager.mirrors.first?.activeTransferID != nil }
        let id = try XCTUnwrap(manager.mirrors.first?.id)
        queue.cancel(try XCTUnwrap(manager.mirrors.first?.activeTransferID), pause: true)
        manager.syncNow(id)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(queue.items.count, 1, "Sync now must reuse a paused job")
        manager.remove(id)
        XCTAssertEqual(queue.items.first?.state, .cancelled)
    }
    func testMegaAndBoxMarkCappedSearchesIncomplete() async throws {
        let mega = api(.mega), state = MegaState(sid: "sid", masterKey: Data(repeating: 1, count: 16))
        state.loaded = true; state.loadedAt = Date()
        for n in 0..<501 { state.nodes["n\(n)"] = MegaNode(handle: "n\(n)", parent: "root", kind: 0, name: "match \(n)", size: 1, modified: nil, key: Data()) }
        mega.megaStateCache = state
        let page = try await mega.searchPage(term: "match")
        XCTAssertEqual(page.hits.count, 500); XCTAssertTrue(page.incomplete)
        StubProtocol.handler = { _ in (200, [:], Data(#"{"total_count":10001,"entries":[{"id":"f","name":"match","type":"file"}]}"#.utf8)) }
        let box = try await api(.box).searchPage(term: "match", cursor: "9999")
        XCTAssertTrue(box.incomplete); XCTAssertNil(box.next)
    }
    func testMegaBudgetRejectsBeforeRequestingFileBytes() async throws {
        let mega = api(.mega), state = MegaState(sid: "sid", masterKey: Data(repeating: 1, count: 16))
        state.loaded = true; state.loadedAt = Date()
        state.nodes["f"] = MegaNode(handle: "f", parent: "root", kind: 0, name: "a", size: 1000, modified: nil, key: Data(repeating: 1, count: 32))
        mega.megaStateCache = state
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1; XCTAssertEqual(request.url?.host, "g.api.mega.co.nz")
            return (200, [:], Data(#"[{"g":"https://storage.example.com/file","s":1000}]"#.utf8))
        }
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        do { try await mega.download(file: file("f"), to: root.appendingPathComponent("out"), maxBytes: 10); XCTFail("Expected limit") } catch {}
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("out").path))
    }
    func testMegaReplacementRetryOnlyRetiresPreviousNode() async throws {
        let mega = api(.mega), state = MegaState(sid: "sid", masterKey: Data(repeating: 1, count: 16))
        state.loaded = true; state.loadedAt = Date()
        state.trash = "trash"
        state.nodes["trash"] = MegaNode(handle: "trash", parent: "", kind: 4, name: "Trash", size: nil, modified: nil, key: Data())
        state.nodes["old"] = MegaNode(handle: "old", parent: "root", kind: 0, name: "a", size: 1, modified: nil, key: Data())
        mega.megaStateCache = state
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("a"); try Data([1]).write(to: local)
        var cursor = UploadCheckpoint(total: 1, remoteID: "new", pendingRetirementID: "old")
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
            XCTAssertEqual(command["a"] as? String, "m", "No upload or node creation may be repeated")
            return (200, [:], Data(calls == 1 ? "[-11]".utf8 : "[0]".utf8))
        }
        do { _ = try await mega.megaUpload(local: local, parent: "root", name: "a", replacing: "old", cursor: &cursor, save: { _ in }, progress: { _, _ in }); XCTFail("Expected retirement error") } catch {}
        XCTAssertEqual(cursor.remoteID, "new"); XCTAssertFalse(cursor.complete)
        XCTAssertEqual(state.nodes["old"]?.parent, "root")
        try FileManager.default.removeItem(at: local)
        let receipt = try await mega.resumableUpload(local: local, parent: "root", name: "a", replacing: "old", checkpoint: cursor, save: { cursor = $0 }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "new"); XCTAssertTrue(cursor.complete)
        XCTAssertEqual(state.nodes["old"]?.parent, "trash"); XCTAssertEqual(calls, 2)
    }

}
