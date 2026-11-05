import XCTest
@testable import iCloudy

/// The fixes of the review of 5 November 2026 that are not about SSH or about the hand-written cryptography.
@MainActor
final class ReviewFixesTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    private func client(_ cloud: Cloud, server: String? = nil, id: String = "review") -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: id, cloud: cloud, name: "Prueba", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: server, bookmark: nil, options: cloud == .pcloud ? ["apiHost": "eapi.pcloud.com"] : [:])
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func query(_ request: URLRequest) -> [String: String] {
        var values: [String: String] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { values[item.name] = item.value ?? "" }
        return values
    }
    private func temporaryURL(_ name: String = UUID().uuidString + ".json") -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("review-" + UUID().uuidString).appendingPathComponent(name)
    }

    // MARK: - Retry-After

    func testRetryAfterReadsSecondsAndHTTPDates() {
        let now = Date(timeIntervalSince1970: 784_111_777)   // Sun, 06 Nov 1994 08:49:37 GMT
        XCTAssertEqual(RetryAfter.seconds("7", now: now), 7)
        XCTAssertEqual(RetryAfter.seconds(" 12 ", now: now), 12)
        XCTAssertEqual(RetryAfter.seconds("Sun, 06 Nov 1994 08:50:37 GMT", now: now), 60, "IMF-fixdate")
        XCTAssertEqual(RetryAfter.seconds("Sunday, 06-Nov-94 08:51:37 GMT", now: now), 120, "RFC 850")
        XCTAssertEqual(RetryAfter.seconds("Sun Nov  6 08:49:47 1994", now: now), 10, "asctime")
        XCTAssertEqual(RetryAfter.seconds("Sun, 06 Nov 1994 08:00:00 GMT", now: now), 0, "Una fecha pasada es «ya»")
        XCTAssertNil(RetryAfter.seconds("pronto", now: now))
        XCTAssertNil(RetryAfter.seconds("-5", now: now))
        XCTAssertNil(RetryAfter.seconds(nil as String?, now: now))

        XCTAssertEqual(RetryAfter.delay(announced: 90, attempt: 0), 90, "Box y Graph piden hasta dos minutos")
        XCTAssertEqual(RetryAfter.delay(announced: 9_999, attempt: 0), RetryAfter.cap)
        XCTAssertEqual(RetryAfter.delay(announced: 0, attempt: 0), 1)
        XCTAssertEqual(RetryAfter.delay(announced: nil, attempt: 2), 4)

        let date = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 503, httpVersion: nil,
                                   headerFields: ["Retry-After": "Sun, 06 Nov 1994 08:49:37 GMT"])!
        do { try HTTP.validate(date, data: Data()); XCTFail("Un 503 es un error") }
        catch let error as ServiceError { XCTAssertNotNil(error.retryAfter, "La forma de fecha ya no se pierde") }
        catch { XCTFail("\(error)") }
    }

    // MARK: - WebDAV retries

    func testWebDAVRepeatsAReadThatNextcloudRefusedWhileInMaintenance() async throws {
        var methods: [String] = []
        StubProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if methods.count == 1 { return (503, ["Retry-After": "0"], Data("maintenance".utf8)) }
            return (207, [:], Data("""
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
            <d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/dav/a.txt</d:href><d:propstat><d:prop><d:getcontentlength>3</d:getcontentlength><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>
            """.utf8))
        }
        let files = try await client(.webdav, server: "https://nube.example.com/dav").list(parent: "root")
        XCTAssertEqual(files.map(\.name), ["a.txt"])
        XCTAssertEqual(methods, ["PROPFIND", "PROPFIND"])
    }

    func testWebDAVDoesNotRepeatACreateTheServerMayHaveApplied() async throws {
        var calls = 0
        StubProtocol.handler = { _ in calls += 1; return (503, ["Retry-After": "0"], Data()) }
        do { _ = try await client(.webdav, server: "https://nube.example.com/dav").createFolder(name: "Nueva", parent: "root"); XCTFail("Un 503 es un error") }
        catch {}
        XCTAssertEqual(calls, 1, "MKCOL no es idempotente")
        XCTAssertTrue(WebDAVProvider.webdavReads.contains("PROPFIND"))
        XCTAssertFalse(WebDAVProvider.webdavReads.contains("MKCOL"))
        XCTAssertFalse(WebDAVProvider.webdavReads.contains("MOVE"))
    }

    // MARK: - Google Drive and shared drives

    func testGooglePersonalAccountsAskForSharedDriveItemsEverywhere() async throws {
        var seen: [URLRequest] = []
        StubProtocol.handler = { request in
            seen.append(request)
            return (200, [:], Data(#"{"files":[{"id":"x","name":"Equipo","mimeType":"application/vnd.google-apps.folder"}],"id":"x","parents":["p"]}"#.utf8))
        }
        let api = client(.google)
        _ = try await api.list(parent: Collection.shared.rootID)
        _ = try await api.list(parent: "folderInASharedDrive")
        _ = try await api.searchPage(term: "plan")
        try await api.rename(file: CloudFile(id: "x", name: "a", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false), name: "b")
        XCTAssertEqual(seen.count, 4)
        for request in seen {
            XCTAssertEqual(query(request)["supportsAllDrives"], "true", request.url!.absoluteString)
        }
        for request in seen.prefix(3) {
            XCTAssertEqual(query(request)["includeItemsFromAllDrives"], "true", request.url!.absoluteString)
        }
        XCTAssertEqual(query(seen[2])["corpora"], "user", "Una cuenta personal sigue buscando en su propio corpus")
        XCTAssertEqual(Set(seen.compactMap { query($0)["supportsAllDrives"] }).count, 1, "Sin parámetros repetidos")
        XCTAssertEqual(seen[3].url!.query!.components(separatedBy: "supportsAllDrives").count, 2)
    }

    // MARK: - Queue checkpoints

    func testAQueueSurvivesUploadCheckpointsItCannotRead() throws {
        // `offset` as text stands for whatever a later version might write there.
        let fixture = Data(#"[{"accountID":"google:1","direction":"upload","localURL":"file:///tmp/a.bin","state":"paused","uploads":{"a.bin":{"offset":"diez"}},"downloads":{"b":7}}]"#.utf8)
        let transfers = try JSONDecoder().decode([Transfer].self, from: fixture)
        XCTAssertEqual(transfers.count, 1)
        XCTAssertTrue(transfers[0].uploads.isEmpty, "Solo se pierde el punto de reanudación, no la cola")
        XCTAssertEqual(transfers[0].state, .paused)
    }

    // MARK: - OneDrive's own bin list

    func testOneDriveJournalReportsAWriteThatFailed() throws {
        // A plain file where the journal's folder should be makes every write fail.
        let blocker = temporaryURL("bloqueo")
        try FileManager.default.createDirectory(at: blocker.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocker)
        let journal = OneDriveBinJournal(url: blocker.appendingPathComponent("onedrive-bin.json"))
        let file = CloudFile(id: "A1", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        XCTAssertThrowsError(try journal.record(file, accountID: "onedrive-1"), "Antes se tragaba el error y la papelera quedaba sin apuntar")
    }

    func testAnUnreadableOneDriveJournalIsSetAsideNotOverwritten() throws {
        let url = temporaryURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ no es json".utf8).write(to: url)
        let journal = OneDriveBinJournal(url: url)
        XCTAssertTrue(journal.items(accountID: "onedrive-1").isEmpty)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(siblings.contains { $0.contains(".corrupt-") }, "El archivo ilegible se aparta: \(siblings)")
        try journal.record(CloudFile(id: "A1", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false), accountID: "onedrive-1")
        XCTAssertEqual(OneDriveBinJournal(url: url).items(accountID: "onedrive-1").map(\.file.id), ["A1"])
    }
}
