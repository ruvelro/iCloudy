import XCTest
@testable import iCloudy

/// A two-way mirror used to list its whole remote tree every five minutes to learn that nothing had happened. Where
/// the provider keeps a feed of changes it is asked that instead, and the tree is listed only when the answer
/// touches it.
@MainActor
final class ChangeFeedTests: XCTestCase {
    private var requests: [URLRequest] = []
    override func setUp() async throws { requests = [] }

    private func client(_ cloud: Cloud, driveID: String? = nil) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let base = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil)
        let account = driveID.map { Account.scoped(to: $0, named: "Unidad", from: base) } ?? base
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func answer(_ responses: [(Int, String)]) {
        var queue = responses
        StubProtocol.handler = { [self] request in
            requests.append(request)
            let (status, body) = queue.isEmpty ? (500, "{}") : queue.removeFirst()
            return (status, [:], Data(body.utf8))
        }
    }
    private func query(_ request: URLRequest?) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: - What counts as a change of a tree

    func testAChangeTouchesATreeByItsIdOrByTheFolderItLandsIn() {
        let known: Set<String> = ["folder", "sub", "file"]
        func touches(_ changes: [RemoteChange], root: String = "folder", scoped: Bool = false, reset: Bool = false) -> Bool {
            ChangeBatch(changes: changes, cursor: "c", scoped: scoped, reset: reset).touches(root: root, known: known, rootAlias: "root")
        }
        XCTAssertFalse(touches([]))
        XCTAssertTrue(touches([RemoteChange(id: "file")]), "Edited, moved away or deleted: it was in the tree")
        XCTAssertTrue(touches([RemoteChange(id: "new", parents: ["sub"])]), "Arrived in one of its folders")
        XCTAssertTrue(touches([RemoteChange(id: "new", parents: ["folder"])]), "Arrived in its root")
        XCTAssertFalse(touches([RemoteChange(id: "other", parents: ["elsewhere"])]), "Somebody else's corner of the account")
        XCTAssertFalse(touches([RemoteChange(id: nil)]))
        XCTAssertTrue(touches([RemoteChange(id: "other", parents: ["elsewhere"])], scoped: true), "The provider already narrowed the feed to the folder")
        XCTAssertTrue(touches([RemoteChange(id: "other", parents: ["0AbCd"])], root: "root"), "The whole account is mirrored: its root is an alias nobody repeats")
        XCTAssertTrue(touches([], reset: true), "A feed that lost its place says nothing about what happened")
    }

    // MARK: - Providers

    func testDriveAsksForAStartTokenAndThenOnlyForWhatFollowedIt() async throws {
        answer([(200, #"{"startPageToken":"100"}"#),
                (200, #"{"nextPageToken":"p2","changes":[{"fileId":"a","removed":false,"file":{"id":"a","parents":["dir"]}}]}"#),
                (200, #"{"newStartPageToken":"140","changes":[{"fileId":"gone","removed":true}]}"#)])
        let api = client(.google)
        let cursor = try await api.changeCursor(for: "dir")
        XCTAssertEqual(cursor, "100")
        XCTAssertEqual(requests[0].url?.path, "/drive/v3/changes/startPageToken")
        let batch = try await api.changes(since: "100", in: "dir")
        XCTAssertEqual(batch.changes, [RemoteChange(id: "a", parents: ["dir"]), RemoteChange(id: "gone")])
        XCTAssertEqual(batch.cursor, "140")
        XCTAssertFalse(batch.scoped); XCTAssertFalse(batch.reset)
        XCTAssertEqual(query(requests[1])["pageToken"], "100"); XCTAssertEqual(query(requests[2])["pageToken"], "p2")
        XCTAssertEqual(query(requests[1])["includeRemoved"], "true")
        XCTAssertNil(query(requests[1])["driveId"])
    }

    func testDriveReadsASharedDriveFromItsOwnFeed() async throws {
        answer([(200, #"{"startPageToken":"7"}"#), (200, #"{"newStartPageToken":"7","changes":[]}"#)])
        let api = client(.google, driveID: "0Shared")
        _ = try await api.changeCursor(for: "root")
        _ = try await api.changes(since: "7", in: "root")
        for request in requests {
            XCTAssertEqual(query(request)["driveId"], "0Shared"); XCTAssertEqual(query(request)["supportsAllDrives"], "true")
        }
        XCTAssertEqual(query(requests[1])["includeItemsFromAllDrives"], "true")
    }

    func testOneDriveFollowsItsDeltaLinkAndStartsOverWhenItIsGone() async throws {
        let link = "https://graph.microsoft.com/v1.0/me/drive/root/delta?token=abc"
        answer([(200, #"{"value":[],"@odata.deltaLink":"\#(link)"}"#),
                (200, #"{"value":[{"id":"x","parentReference":{"id":"dir"}},{"id":"dir"}],"@odata.deltaLink":"\#(link)2"}"#),
                (410, #"{"error":{"code":"resyncRequired","message":"Resync required"}}"#),
                (200, #"{"value":[],"@odata.deltaLink":"\#(link)3"}"#)])
        let api = client(.microsoft)
        let cursor = try await api.changeCursor(for: "dir")
        XCTAssertEqual(cursor, link)
        XCTAssertEqual(query(requests[0])["token"], "latest", "The first position costs no enumeration of the drive")
        var batch = try await api.changes(since: link, in: "dir")
        XCTAssertEqual(batch.changes, [RemoteChange(id: "x", parents: ["dir"]), RemoteChange(id: "dir")])
        XCTAssertEqual(batch.cursor, link + "2")
        batch = try await api.changes(since: link + "2", in: "dir")
        XCTAssertTrue(batch.reset); XCTAssertEqual(batch.cursor, link + "3")
    }

    func testOneDriveNeverSendsItsTokenToALinkThatIsNotGraphs() async throws {
        answer([])
        do { _ = try await client(.microsoft).changes(since: "https://evil.example/delta?token=abc", in: "dir"); XCTFail("Not a Graph link") }
        catch { XCTAssertTrue(requests.isEmpty, "Nothing was sent anywhere") }
    }

    func testDropboxScopesItsCursorToTheFolder() async throws {
        answer([(200, #"{"cursor":"c1"}"#),
                (200, #"{"entries":[{".tag":"file","name":"a.txt","path_lower":"/fotos/a.txt"}],"cursor":"c2","has_more":true}"#),
                (200, #"{"entries":[{".tag":"deleted","name":"b.txt","path_lower":"/fotos/b.txt"}],"cursor":"c3","has_more":false}"#),
                (409, #"{"error_summary":"reset/..","error":{".tag":"reset"}}"#),
                (200, #"{"cursor":"c9"}"#)])
        let api = client(.dropbox)
        let cursor = try await api.changeCursor(for: "/fotos")
        XCTAssertEqual(cursor, "c1")
        XCTAssertEqual(requests[0].url?.path, "/2/files/list_folder/get_latest_cursor")
        let asked = try XCTUnwrap(JSONSerialization.jsonObject(with: requestData(requests[0])) as? [String: Any])
        XCTAssertEqual(asked["path"] as? String, "/fotos"); XCTAssertEqual(asked["recursive"] as? Bool, true); XCTAssertEqual(asked["include_deleted"] as? Bool, true)
        var batch = try await api.changes(since: "c1", in: "/fotos")
        XCTAssertEqual(batch.changes.map(\.id), ["/fotos/a.txt", "/fotos/b.txt"])
        XCTAssertEqual(batch.cursor, "c3"); XCTAssertTrue(batch.scoped)
        batch = try await api.changes(since: "c3", in: "/fotos")
        XCTAssertTrue(batch.reset); XCTAssertEqual(batch.cursor, "c9")
    }

    func testBoxDrainsItsEventStream() async throws {
        answer([(200, #"{"chunk_size":0,"next_stream_position":1000,"entries":[]}"#),
                (200, #"{"chunk_size":1,"next_stream_position":"1001","entries":[{"event_type":"ITEM_UPLOAD","source":{"type":"file","id":"55","parent":{"type":"folder","id":"9"}}}]}"#),
                (200, #"{"chunk_size":0,"next_stream_position":"1001","entries":[]}"#)])
        let api = client(.box)
        let cursor = try await api.changeCursor(for: "9")
        XCTAssertEqual(cursor, "1000", "Box writes the position as a number here and as a string there")
        XCTAssertEqual(query(requests[0])["stream_position"], "now")
        let batch = try await api.changes(since: "1000", in: "9")
        XCTAssertEqual(batch.changes, [RemoteChange(id: "55", parents: ["9"])])
        XCTAssertEqual(batch.cursor, "1001")
        XCTAssertEqual(query(requests[1])["stream_type"], "changes")
    }

    func testProvidersWithoutAFeedSayThereIsNone() async throws {
        for cloud in [Cloud.webdav, .ftp, .sftp, .mega, .o2, .pcloud, .s3] {
            var account = Account(id: "x", cloud: cloud, name: "X", email: "x", clientID: "", clientSecret: nil)
            account.serverURL = "https://nas.example/dav"
            let cursor = try await CloudAPI(account: account, tokenProvider: { "t" }).changeCursor(for: "root")
            XCTAssertNil(cursor, cloud.rawValue)
        }
    }

    // MARK: - The mirror's remote poll

    private func manager(_ api: CloudAPI) throws -> (MirrorManager, UUID, TransferQueue) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("feed-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("local"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(storeURL: root.appendingPathComponent("transfers.json"))
        queue.client = { _ in api }
        let manager = MirrorManager(storeURL: root.appendingPathComponent("mirrors.json"))
        manager.watching = false
        manager.queue = queue
        // No account lookup: a scheduled run stops before it touches anything, and stays visible as pending.
        let folder = CloudFile(id: "dir", name: "Fotos", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        try manager.add(local: root.appendingPathComponent("local"), account: api.account, folder: folder, path: [], mode: .twoWay)
        return (manager, try XCTUnwrap(manager.mirrors.first?.id), queue)
    }
    private func settle(_ manager: MirrorManager) async throws {
        try await Task.sleep(for: .milliseconds(30))
    }

    func testAQuietFeedCostsOneRequestAndNoListing() async throws {
        let api = client(.google)
        let (manager, id, queue) = try manager(api); _ = queue
        try await settle(manager)
        manager.adoptFeedPosition("100", known: ["dir", "a"], for: id)
        answer([(200, #"{"newStartPageToken":"101","changes":[{"fileId":"z","file":{"id":"z","parents":["elsewhere"]}}]}"#)])
        let before = manager.pending
        await manager.remoteTick(id)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(manager.feedCursors[id], "101", "Next time it asks from where this answer ended")
        XCTAssertEqual(manager.pending, before, "Nothing of this tree changed, so nothing is planned")
    }

    func testAChangeInsideTheTreePlansARun() async throws {
        let api = client(.google)
        let (manager, id, queue) = try manager(api); _ = queue
        try await settle(manager)
        manager.adoptFeedPosition("100", known: ["dir", "a"], for: id)
        answer([(200, #"{"newStartPageToken":"101","changes":[{"fileId":"n","file":{"id":"n","parents":["dir"]}}]}"#)])
        await manager.remoteTick(id)
        XCTAssertNil(manager.feedCursors[id], "The run takes its own position before it lists")
        XCTAssertTrue(manager.pending.contains(id))
    }

    func testAFeedThatFailsFallsBackToListing() async throws {
        let api = client(.google)
        let (manager, id, queue) = try manager(api); _ = queue
        try await settle(manager)
        manager.adoptFeedPosition("100", known: ["dir"], for: id)
        answer([(403, #"{"error":{"code":403,"message":"Forbidden"}}"#)])
        await manager.remoteTick(id)
        XCTAssertNil(manager.feedCursors[id], "Silence is not 'nothing changed'")
    }

    func testWithoutAPositionTheTreeIsListedAsBefore() async throws {
        let api = client(.google)
        let (manager, id, queue) = try manager(api); _ = queue
        try await settle(manager)
        answer([])
        await manager.remoteTick(id)
        XCTAssertTrue(requests.isEmpty, "The feed is not asked without a position to ask from")
        XCTAssertTrue(manager.pending.contains(id))
    }
}
