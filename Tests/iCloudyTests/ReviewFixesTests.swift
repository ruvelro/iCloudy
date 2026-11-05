import XCTest
import Network
@testable import iCloudy

/// The browser, for the loopback tests here: one GET over TCP, the answer as text, or nil if the listener hung up.
private func browserGET(_ url: URL) async -> String? {
    guard let port = url.port.flatMap({ NWEndpoint.Port(rawValue: UInt16($0)) }) else { return nil }
    let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
    final class Once: @unchecked Sendable { var done = false }
    let once = Once()
    return await withCheckedContinuation { continuation in
        let finish: @Sendable (String?) -> Void = { text in
            guard !once.done else { return }
            once.done = true; connection.cancel(); continuation.resume(returning: text)
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let request = "GET \(url.path)?\(url.query ?? "") HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        finish(data.flatMap { $0.isEmpty ? nil : String(decoding: $0, as: UTF8.self) })
                    }
                })
            case .failed, .cancelled: finish(nil)
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "review-browser"))
    }
}
private final class Seen: @unchecked Sendable { var answers: [String?] = [] }

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

    // MARK: - pCloud's callback without state

    private func pcloudSignIn(confirm: Bool, asked: Locked<[LoginPrompts.AccountQuestion]>, seen: Seen) async throws -> (Account, Credential) {
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/oauth2_token": return (200, [:], Data(#"{"result":0,"access_token":"tok","locationid":1}"#.utf8))
            case "/userinfo": return (200, [:], Data(#"{"result":0,"userid":7,"email":"ana@example.com"}"#.utf8))
            default: XCTFail(request.url!.absoluteString); return (500, [:], Data())
            }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let oauth = OAuth(session: URLSession(configuration: config), openURL: { url in
            let redirect = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }!.value!
            _ = Task.detached {
                seen.answers.append(await browserGET(URL(string: redirect + "?code=the-code&locationid=1")!))
                // A second answer without state, as a hostile page would send: dropped without a reply.
                seen.answers.append(await browserGET(URL(string: redirect + "?code=evil&locationid=1")!))
            }
            return true
        }, confirmAccount: { question in asked.set(asked.get() + [question]); return confirm })
        let watchdog = Task { try? await Task.sleep(for: .seconds(20)); oauth.cancel() }
        defer { watchdog.cancel() }
        // pCloud's port is fixed, and the previous listener (or another test run on this Mac) may still hold it.
        for _ in 0..<50 {
            do { return try await oauth.signIn(cloud: .pcloud, clientID: "client", clientSecret: "secret") }
            catch where error.localizedDescription.contains("\(OAuthRequest.defaultPort)") || error.localizedDescription.contains("53.682") {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        throw XCTSkip("El puerto de pCloud sigue ocupado")
    }

    func testAPCloudCallbackWithoutStateConnectsOnlyAnAccountThePersonConfirms() async throws {
        let asked = Locked<[LoginPrompts.AccountQuestion]>([]), seen = Seen()
        let (account, _) = try await pcloudSignIn(confirm: true, asked: asked, seen: seen)
        XCTAssertEqual(account.email, "ana@example.com")
        XCTAssertEqual(asked.get(), [LoginPrompts.AccountQuestion(service: Cloud.pcloud.title, email: "ana@example.com")])
        for _ in 0..<200 where seen.answers.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(seen.answers.first??.hasPrefix("HTTP/1.1 200") == true)

        let refused = Locked<[LoginPrompts.AccountQuestion]>([])
        do { _ = try await pcloudSignIn(confirm: false, asked: refused, seen: Seen()); XCTFail("Sin confirmar no se guarda") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ana@example.com"), error.localizedDescription) }
        XCTAssertEqual(refused.get().count, 1)
    }

    func testOnlyTheFirstStatelessCallbackIsTakenAndOnlyByPCloud() throws {
        XCTAssertEqual(try OAuthRequest.callbackCode(target: "/callback?code=a", expectedState: "s", toleratesMissingState: true), "a")
        XCTAssertThrowsError(try OAuthRequest.callbackCode(target: "/callback?code=a", expectedState: "s"), "Google, Box, Dropbox y Microsoft exigen state")
        for cloud in [Cloud.google, .box, .dropbox, .microsoft] {
            XCTAssertEqual(OAuthProviderSettings.settings(for: cloud)?.toleratesMissingState, false, cloud.rawValue)
        }
        XCTAssertLessThanOrEqual(OAuth.statelessWindow, 300)
    }

    // MARK: - Dropbox's bin, a folder at a time

    func testDropboxsBinIsBrowsedAFolderAtATimeInsteadOfWalkingTheAccount() async throws {
        var bodies: [String] = []
        StubProtocol.handler = { request in
            bodies.append(requestBody(request))
            return (200, [:], Data(#"{"entries":[{".tag":"deleted","name":"viejo.txt","path_lower":"/fotos/viejo.txt"},{".tag":"folder","name":"Viaje","path_lower":"/fotos/viaje"},{".tag":"file","name":"vivo.txt","path_lower":"/fotos/vivo.txt","size":1}],"has_more":false}"#.utf8))
        }
        let api = client(.dropbox)
        let listed = try await api.list(parent: Collection.trashFolderPrefix + "/fotos")
        XCTAssertEqual(listed.map(\.id), [Collection.trashFolderPrefix + "/fotos/viaje", "/fotos/viejo.txt"], "Lo borrado y las carpetas por las que seguir")
        XCTAssertTrue(listed[0].isFolder)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(bodies[0].utf8)) as? [String: Any])
        XCTAssertEqual(body["path"] as? String, "/fotos")
        XCTAssertEqual(body["include_deleted"] as? Bool, true)
        XCTAssertNil(body["recursive"], "Nunca la cuenta entera")
        do { try await api.restore(file: listed[0]); XCTFail("Una carpeta viva no se restaura") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no está borrada"), error.localizedDescription) }
    }

    // MARK: - Pagination

    func testADropboxCursorHandedOutTwiceEndsTheListingInsteadOfLoopingForEver() async throws {
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            let name = "f\(calls).txt"
            return (200, [:], Data(#"{"entries":[{".tag":"file","name":"\#(name)","path_lower":"/\#(name)","size":1}],"has_more":true,"cursor":"siempre-el-mismo"}"#.utf8))
        }
        do { _ = try await client(.dropbox).list(parent: "root"); XCTFail("Un cursor repetido no puede seguir para siempre") }
        catch { XCTAssertTrue(error is Pagination.Looping, "\(error)") }
        XCTAssertEqual(calls, 2, "La primera página y una sola repetición")

        var pages: [Int] = []
        try await Pagination.follow(first: ["n": 1], cursor: { ($0["n"] as! Int) < 3 ? "c\($0["n"] as! Int)" : nil },
                                    next: { ["n": Int($0.dropFirst())! + 1] }, each: { pages.append($0["n"] as! Int) })
        XCTAssertEqual(pages, [1, 2, 3])
    }

    // MARK: - pCloud's search tree

    func testPCloudKeepsTheSearchTreeForAWhileAndDropsItOnAChange() async throws {
        var trees = 0
        StubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "listfolder":
                trees += 1
                return (200, [:], Data(#"{"result":0,"metadata":{"id":"d0","folderid":0,"name":"/","isfolder":true,"contents":[{"id":"d5","folderid":5,"name":"Viaje","isfolder":true,"contents":[{"id":"f9","fileid":9,"name":"viaje.jpg","isfolder":false,"size":3,"modified":1700000000}]}]}}"#.utf8))
            default: return (200, [:], Data(#"{"result":0,"metadata":{"id":"d6","folderid":6,"name":"Nueva","isfolder":true}}"#.utf8))
            }
        }
        let api = client(.pcloud)
        let now = Date()
        let first = try await api.searchPage(term: "viaje", referenceDate: now)
        XCTAssertEqual(first.hits.map(\.file.name), ["Viaje", "viaje.jpg"])
        XCTAssertEqual(first.hits.last?.parentID, "d5")
        _ = try await api.searchPage(term: "jpg", referenceDate: now.addingTimeInterval(60))
        XCTAssertEqual(trees, 1, "Otra búsqueda al minuto usa el mismo árbol")
        _ = try await api.searchPage(term: "jpg", referenceDate: now.addingTimeInterval(PCloudProvider.searchIndexMaxAge + 1))
        XCTAssertEqual(trees, 2, "Pasado el plazo se vuelve a pedir")
        _ = try await api.createFolder(name: "Nueva", parent: "root")
        _ = try await api.searchPage(term: "jpg", referenceDate: now.addingTimeInterval(PCloudProvider.searchIndexMaxAge + 2))
        XCTAssertEqual(trees, 3, "Un cambio hecho desde aquí invalida el árbol")
    }

    // MARK: - Explicit FTPS

    func testEachExplicitFTPSConnectionCarriesItsOwnServerName() {
        // Two sessions opening at once used to share one static table and could verify against each other's host.
        let first = StartTLSFramer.options(serverName: "nas.example.com")
        let second = StartTLSFramer.options(serverName: "192.168.1.20")
        XCTAssertEqual(StartTLSFramer.serverName(in: first), "nas.example.com")
        XCTAssertEqual(StartTLSFramer.serverName(in: second), "192.168.1.20")
        XCTAssertNil(StartTLSFramer.serverName(in: NWProtocolFramer.Options(definition: StartTLSFramer.definition)), "Sin nombre, la verificación falla cerrada")
        XCTAssertTrue(StartTLSFramer.isAddressLiteral("192.168.1.20"))
        XCTAssertTrue(StartTLSFramer.isAddressLiteral("[fe80::1]"))
        XCTAssertFalse(StartTLSFramer.isAddressLiteral("nas.example.com"))
    }

    // MARK: - Mega's second factor

    func testMegaAsksForTheSecondFactorWhenItIsNeededAndKeepsThePasswordWhole() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        var logins: [(uh: String?, mfa: String?)] = []
        StubProtocol.handler = { request in
            let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
            switch command["a"] as? String {
            case "us0": return (200, [:], try JSONSerialization.data(withJSONObject: [["s": MegaCrypto.encode(Data(count: 16)), "v": 2]]))
            default:
                logins.append((command["uh"] as? String, command["mfa"] as? String))
                if command["mfa"] as? String != "654321" { return (200, [:], Data("[-26]".utf8)) }
                // A key that does not unwrap: enough to show the code got the request past the second factor.
                return (200, [:], try JSONSerialization.data(withJSONObject: [["k": MegaCrypto.encode(Data(count: 8))]]))
            }
        }
        let retries = Locked<[Bool]>([])
        let answers = Locked<[String]>(["111111", "654321"])
        do {
            _ = try await MegaAPI.signIn(email: "ana@ejemplo.com", password: "frase con 123456", code: nil, askCode: { retry in
                retries.set(retries.get() + [retry])
                let next = answers.get().first; answers.set(Array(answers.get().dropFirst())); return next
            }, session: URLSession(configuration: configuration))
            XCTFail("La clave de prueba no desenvuelve")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("contraseña de Mega no es correcta"), error.localizedDescription)
        }
        XCTAssertEqual(logins.map(\.mfa), [nil, "111111", "654321"])
        XCTAssertEqual(Set(logins.map(\.uh)).count, 1, "La misma prueba derivada: la contraseña entera, con su espacio y sus cifras")
        XCTAssertEqual(retries.get(), [false, true], "La segunda vez se dice que el código no valía")
    }

    func testMegaSecondFactorGivenUpIsReportedAsSuch() async throws {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { request in
            let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
            if command["a"] as? String == "us0" { return (200, [:], try JSONSerialization.data(withJSONObject: [["s": MegaCrypto.encode(Data(count: 16)), "v": 2]])) }
            return (200, [:], Data("[-26]".utf8))
        }
        do {
            _ = try await MegaAPI.signIn(email: "ana@ejemplo.com", password: "x", code: nil, askCode: { _ in nil },
                                         session: URLSession(configuration: configuration))
            XCTFail("Sin código no hay sesión")
        } catch { XCTAssertTrue(error is MegaTwoFactorRequired, "\(error)") }
    }

    func testLoginPromptsResumeTheWaitingSignIn() async {
        let prompts = LoginPrompts()
        async let trusted = prompts.trust(LoginPrompts.HostKeyQuestion(host: "nas", port: 2222, blob: Data()))
        while prompts.hostKey == nil { await Task.yield() }
        XCTAssertEqual(prompts.hostKey?.server, "nas:2222")
        prompts.answerHostKey(true)
        let answer = await trusted
        XCTAssertTrue(answer)
        XCTAssertNil(prompts.hostKey)

        async let code = prompts.code(LoginPrompts.CodeQuestion(service: "Mega", retry: false))
        while prompts.code == nil { await Task.yield() }
        prompts.answerCode("  123456 ")
        let typed = await code
        XCTAssertEqual(typed, "123456")
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
