import XCTest
@testable import iCloudy

/// Public link management, provider by provider: the request each one sends, what is read back from the answer,
/// how refusals are explained, and which options the interface may offer at all.
@MainActor
final class PublicLinkTests: XCTestCase {
    private var seen: [(method: String, host: String, path: String, query: [String: String], body: String)] = []
    override func setUp() { seen = [] }
    override func tearDown() { StubProtocol.handler = nil }

    private func client(_ cloud: Cloud, options: [String: String] = [:]) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test", cloud: cloud, name: "Test", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: cloud == .webdav ? "https://nube.example.com/remote.php/dav/files/ana" : nil, bookmark: nil, options: options)
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func item(_ id: String, folder: Bool = false, web: String? = nil) -> CloudFile {
        CloudFile(id: id, name: folder ? "Proyecto" : "informe.pdf", mime: folder ? "application/vnd.google-apps.folder" : "application/pdf",
                  size: 1, modified: nil, webURL: web.flatMap(URL.init(string:)), isFolder: folder)
    }
    private func serve(_ answer: @escaping (String, String, String) -> (Int, Data)) {
        StubProtocol.handler = { [self] request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let body = requestBody(request)
            seen.append((request.httpMethod ?? "", parts.host ?? "", parts.path, query, body))
            let (status, data) = answer(request.httpMethod ?? "", parts.path, body)
            return (status, [:], data)
        }
    }
    private var paths: [String] { seen.map { "\($0.method) \($0.path)" } }
    private func json(_ body: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:] }
    private let expiry = ISO8601DateFormatter().date(from: "2026-11-30T22:59:59Z")!

    // MARK: - Capabilities

    func testEachProviderDeclaresWhatItsLinksCanDo() {
        let drive = Cloud.google.capabilities.links, graph = Cloud.microsoft.capabilities.links
        let dropbox = Cloud.dropbox.capabilities.links, box = Cloud.box.capabilities.links, mega = Cloud.mega.capabilities.links
        XCTAssertTrue(drive.manage && drive.expiration && drive.edit && drive.inventory)
        XCTAssertFalse(drive.password, "Drive no protege enlaces con contraseña")
        XCTAssertTrue(graph.password && graph.expiration)
        XCTAssertFalse(graph.inventory, "Graph no lista todos los enlaces de una unidad")
        XCTAssertTrue(dropbox.downloadToggle && dropbox.inventory && dropbox.password)
        XCTAssertFalse(dropbox.editFolders)
        XCTAssertTrue(box.manage && box.downloadToggle); XCTAssertFalse(box.inventory); XCTAssertFalse(box.editFolders)
        XCTAssertTrue(mega.manage && mega.inventory)
        XCTAssertFalse(mega.expiration || mega.password || mega.edit, "Mega solo hace enlaces simples desde iCloudy")
        for cloud in [Cloud.webdav, .ftp, .sftp, .volume, .o2] { XCTAssertEqual(cloud.capabilities.links, LinkFeatures(), "\(cloud)") }
        var nextcloud = Account(id: "w", cloud: .webdav, name: "", email: "", clientID: "", clientSecret: nil, serverURL: "https://n.example.com/remote.php/dav/files/a")
        nextcloud.options["flavor"] = "nextcloud"
        XCTAssertEqual(nextcloud.capabilities.links, .nextcloud)
        XCTAssertFalse(Account.demo.capabilities.links.manage, "La demo no simula enlaces gestionables")
    }

    func testUnsupportedOptionsAreRefusedBeforeAnyRequest() async {
        serve { _, _, _ in XCTFail("No debe salir ninguna petición"); return (500, Data()) }
        var options = PublicLinkOptions(); options.password = "secreta"
        do { _ = try await client(.google).createPublicLink(for: item("f1"), options: options); XCTFail("Drive no admite contraseña") }
        catch { XCTAssertTrue(error.localizedDescription.contains("contraseña"), error.localizedDescription) }
        options = PublicLinkOptions(); options.access = .edit
        do { _ = try await client(.dropbox).createPublicLink(for: item("/carpeta", folder: true), options: options); XCTFail("Dropbox no edita carpetas") }
        catch { XCTAssertTrue(error.localizedDescription.contains("archivos"), error.localizedDescription) }
        options = PublicLinkOptions(); options.allowDownload = false
        do { _ = try await client(.microsoft).createPublicLink(for: item("X"), options: options); XCTFail("Graph no desactiva descargas") }
        catch { XCTAssertTrue(error.localizedDescription.contains("descarga"), error.localizedDescription) }
        do { _ = try await client(.microsoft).allPublicLinks(); XCTFail("OneDrive no enumera enlaces") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Microsoft Graph"), error.localizedDescription) }
        do { _ = try await client(.ftp).publicLinks(for: item("/x")); XCTFail("FTP no tiene enlaces") }
        catch { XCTAssertTrue(error.localizedDescription.contains("FTP"), error.localizedDescription) }
        XCTAssertTrue(seen.isEmpty)
        XCTAssertNil(LinkFeatures.nextcloud.refusal(of: PublicLinkOptions(access: .edit, expires: expiry, password: "x", allowDownload: true), for: item("/a", folder: true), cloud: .webdav))
    }

    func testDatesAreWrittenTheWayEachAPIExpects() {
        XCTAssertEqual(LinkDates.iso(expiry), "2026-11-30T22:59:59Z", "Dropbox exige segundos enteros y Z")
        var madrid = Calendar(identifier: .gregorian); madrid.timeZone = TimeZone(identifier: "Europe/Madrid")!
        XCTAssertEqual(LinkDates.day(expiry, calendar: madrid), "2026-11-30")
        let end = LinkDates.endOfDay(expiry, calendar: madrid)
        XCTAssertEqual(madrid.dateComponents([.hour, .minute, .second], from: end), DateComponents(hour: 23, minute: 59, second: 59))
        XCTAssertNotNil(LinkDates.ocs("2026-10-31 00:00:00")); XCTAssertNil(LinkDates.ocs(""))
    }

    // MARK: - Google Drive

    func testDriveListsAnyoneGrantsAsLinksAndCreatesThemWithAnExpiry() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"permissions":[{"id":"p0","type":"user","role":"owner"},{"id":"anyoneWithLink","type":"anyone","role":"writer","expirationTime":"2026-11-30T22:59:59.000Z"}]}"#.utf8))
            }
            if method == "POST" { return (200, Data(#"{"id":"anyoneWithLink","type":"anyone","role":"reader","expirationTime":"2026-11-30T22:59:59.000Z"}"#.utf8)) }
            return (204, Data())
        }
        let api = client(.google)
        let file = item("f1", web: "https://drive.google.com/file/d/f1/view")
        let links = try await api.publicLinks(for: file)
        XCTAssertEqual(links.count, 1, "El propietario no es un enlace")
        XCTAssertEqual(links[0].handle, "anyoneWithLink"); XCTAssertEqual(links[0].access, .edit)
        XCTAssertEqual(links[0].expires, expiry); XCTAssertEqual(links[0].url, file.webURL)
        XCTAssertEqual(seen[0].query["fields"]?.contains("expirationTime"), true)

        let created = try await api.createPublicLink(for: file, options: PublicLinkOptions(expires: expiry))
        XCTAssertEqual(paths[1], "POST /drive/v3/files/f1/permissions")
        let body = json(seen[1].body)
        XCTAssertEqual(body["type"] as? String, "anyone"); XCTAssertEqual(body["role"] as? String, "reader")
        XCTAssertEqual(body["expirationTime"] as? String, "2026-11-30T22:59:59Z")
        XCTAssertEqual(created.expires, expiry)

        try await api.revokePublicLink(links[0])
        XCTAssertEqual(paths[2], "DELETE /drive/v3/files/f1/permissions/anyoneWithLink")
    }

    func testDriveExplainsAnExpiryTheAccountDoesNotAllow() async throws {
        serve { _, _, _ in (400, Data(#"{"error":{"code":400,"message":"Expiration dates cannot be set on this item.","errors":[{"reason":"expirationDatesMustBeInTheFuture"}]}}"#.utf8)) }
        do { _ = try await client(.google).createPublicLink(for: item("f1"), options: PublicLinkOptions(expires: expiry)); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("No se ha creado ningún enlace"), error.localizedDescription) }
        XCTAssertEqual(seen.count, 1, "No se reintenta sin caducidad a espaldas de la persona")
    }

    func testDriveInventorySearchesByVisibilityAndKeepsEachLinksPermission() async throws {
        serve { _, _, _ in
            (200, Data(#"{"files":[{"id":"a","name":"Plan.pdf","mimeType":"application/pdf","webViewLink":"https://drive.google.com/a","permissions":[{"id":"o","type":"user","role":"owner"},{"id":"anyoneWithLink","type":"anyone","role":"reader"}]},{"id":"b","name":"Web","mimeType":"application/vnd.google-apps.folder","webViewLink":"https://drive.google.com/b","permissions":[{"id":"anyone","type":"anyone","role":"reader","allowFileDiscovery":true}]}]}"#.utf8))
        }
        let links = try await client(.google).allPublicLinks()
        let query = try XCTUnwrap(seen.first?.query["q"])
        XCTAssertTrue(query.contains("visibility = 'anyoneWithLink'") && query.contains("'me' in owners") && query.contains("trashed = false"), query)
        XCTAssertEqual(links.map(\.file.id), ["a", "b"])
        XCTAssertEqual(links.map(\.handle), ["anyoneWithLink", "anyone"])
        XCTAssertNotNil(links[1].audience, "Un enlace público en la web se distingue")
        XCTAssertNotEqual(links[0].id, links[1].id)
    }

    // MARK: - OneDrive

    func testOneDriveCreatesLinksWithExpiryAndPasswordAndListsOnlyLinkPermissions() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"value":[{"id":"a","roles":["owner"],"grantedToV2":{"user":{"displayName":"Ana"}}},{"id":"l1","roles":["read"],"hasPassword":true,"expirationDateTime":"2026-11-30T22:59:59Z","link":{"scope":"anonymous","type":"view","webUrl":"https://1drv.ms/x"}},{"id":"l2","roles":["write"],"link":{"scope":"organization","type":"edit","webUrl":"https://1drv.ms/y"},"inheritedFrom":{"id":"p"}}]}"#.utf8))
            }
            if path.hasSuffix("/createLink") {
                return (201, Data(#"{"id":"l3","roles":["write"],"hasPassword":true,"expirationDateTime":"2026-11-30T22:59:59Z","link":{"scope":"anonymous","type":"edit","webUrl":"https://1drv.ms/z"}}"#.utf8))
            }
            return (204, Data())
        }
        let api = client(.microsoft)
        let links = try await api.publicLinks(for: item("X"))
        XCTAssertEqual(links.map(\.handle), ["l1", "l2"])
        XCTAssertTrue(links[0].hasPassword); XCTAssertEqual(links[0].expires, expiry); XCTAssertNil(links[0].audience)
        XCTAssertEqual(links[1].access, .edit); XCTAssertNotNil(links[1].audience); XCTAssertFalse(links[1].canRevoke)

        let created = try await api.createPublicLink(for: item("X"), options: PublicLinkOptions(access: .edit, expires: expiry, password: "Secreta1", allowDownload: true))
        XCTAssertEqual(paths[1], "POST /v1.0/me/drive/items/X/createLink")
        let body = json(seen[1].body)
        XCTAssertEqual(body["type"] as? String, "edit"); XCTAssertEqual(body["scope"] as? String, "anonymous")
        XCTAssertEqual(body["password"] as? String, "Secreta1"); XCTAssertEqual(body["expirationDateTime"] as? String, "2026-11-30T22:59:59Z")
        XCTAssertEqual(created.url?.absoluteString, "https://1drv.ms/z")

        try await api.revokePublicLink(links[0])
        XCTAssertEqual(paths[2], "DELETE /v1.0/me/drive/items/X/permissions/l1")
        do { try await api.revokePublicLink(links[1]); XCTFail("Un enlace heredado se revoca en la carpeta padre") }
        catch { XCTAssertEqual(seen.count, 3) }
    }

    func testOneDriveSaysSoWhenItHandsBackAnOlderLinkWithoutTheSettings() async throws {
        serve { _, _, _ in (200, Data(#"{"id":"l1","roles":["read"],"link":{"scope":"anonymous","type":"view","webUrl":"https://1drv.ms/x"}}"#.utf8)) }
        do { _ = try await client(.microsoft).createPublicLink(for: item("X"), options: PublicLinkOptions(expires: expiry)); XCTFail("Debe avisar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ya existía"), error.localizedDescription) }
        serve { _, _, _ in (403, Data(#"{"error":{"code":"accessDenied","message":"Expiration requires a premium subscription."}}"#.utf8)) }
        do { _ = try await client(.microsoft).createPublicLink(for: item("X"), options: PublicLinkOptions(expires: expiry)); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("premium") && error.localizedDescription.contains("Microsoft 365"), error.localizedDescription) }
    }

    // MARK: - Dropbox

    private let dropboxLink = #"{".tag":"file","url":"https://www.dropbox.com/s/abc/informe.pdf?dl=0","name":"informe.pdf","path_lower":"/informe.pdf","expires":"2026-11-30T22:59:59Z","link_permissions":{"resolved_visibility":{".tag":"password"},"allow_download":false,"link_access_level":{".tag":"viewer"}}}"#

    func testDropboxSendsEverySettingAndReadsTheLinkBack() async throws {
        serve { [dropboxLink] _, path, _ in
            switch path {
            case "/2/sharing/create_shared_link_with_settings": return (200, Data(dropboxLink.utf8))
            case "/2/sharing/list_shared_links": return (200, Data(("{\"links\":[" + dropboxLink + "],\"has_more\":false}").utf8))
            default: return (200, Data("{}".utf8))
            }
        }
        let api = client(.dropbox)
        let created = try await api.createPublicLink(for: item("/informe.pdf"), options: PublicLinkOptions(expires: expiry, password: "Secreta1", allowDownload: false))
        let settings = try XCTUnwrap(json(seen[0].body)["settings"] as? [String: Any])
        XCTAssertEqual(settings["audience"] as? String, "public"); XCTAssertEqual(settings["access"] as? String, "viewer")
        XCTAssertEqual(settings["expires"] as? String, "2026-11-30T22:59:59Z")
        XCTAssertEqual(settings["require_password"] as? Bool, true); XCTAssertEqual(settings["link_password"] as? String, "Secreta1")
        XCTAssertEqual(settings["allow_download"] as? Bool, false)
        XCTAssertTrue(created.hasPassword); XCTAssertEqual(created.allowsDownload, false); XCTAssertEqual(created.expires, expiry)

        let links = try await api.publicLinks(for: item("/informe.pdf"))
        XCTAssertEqual(json(seen[1].body)["direct_only"] as? Bool, true)
        try await api.revokePublicLink(links[0])
        XCTAssertEqual(paths.last, "POST /2/sharing/revoke_shared_link")
        XCTAssertEqual(json(seen.last!.body)["url"] as? String, "https://www.dropbox.com/s/abc/informe.pdf?dl=0")
    }

    func testDropboxNamesThePaidPlanWhenItRefusesTheSettings() async throws {
        serve { _, _, _ in (409, Data(#"{"error_summary":"settings_error/not_authorized/..","error":{".tag":"settings_error","settings_error":{".tag":"not_authorized"}}}"#.utf8)) }
        do { _ = try await client(.dropbox).createPublicLink(for: item("/a.pdf"), options: PublicLinkOptions(expires: expiry)); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("plan de pago"), error.localizedDescription) }
    }

    func testDropboxChangesTheExistingLinkInsteadOfFailing() async throws {
        serve { [dropboxLink] _, path, _ in
            switch path {
            case "/2/sharing/create_shared_link_with_settings":
                return (409, Data(#"{"error_summary":"shared_link_already_exists/metadata/..","error":{".tag":"shared_link_already_exists"}}"#.utf8))
            case "/2/sharing/list_shared_links": return (200, Data(("{\"links\":[" + dropboxLink + "],\"has_more\":false}").utf8))
            default: return (200, Data(dropboxLink.utf8))
            }
        }
        _ = try await client(.dropbox).createPublicLink(for: item("/informe.pdf"), options: PublicLinkOptions(password: "Otra1234"))
        XCTAssertEqual(paths, ["POST /2/sharing/create_shared_link_with_settings", "POST /2/sharing/list_shared_links", "POST /2/sharing/modify_shared_link_settings"])
        let body = json(seen[2].body)
        XCTAssertEqual(body["url"] as? String, "https://www.dropbox.com/s/abc/informe.pdf?dl=0")
        XCTAssertEqual(body["remove_expiration"] as? Bool, true, "Lo que no se pide se quita, no se arrastra")
        XCTAssertNil((body["settings"] as? [String: Any])?["access"], "El nivel de acceso de un enlace existente no se cambia")
    }

    func testDropboxInventoryFollowsTheCursor() async throws {
        serve { [dropboxLink] _, _, body in
            body.contains("cursor")
                ? (200, Data(#"{"links":[{".tag":"folder","url":"https://www.dropbox.com/sh/f","name":"Fotos","path_lower":"/fotos","link_permissions":{"link_access_level":{".tag":"viewer"},"effective_audience":{".tag":"team"}}}],"has_more":false}"#.utf8))
                : (200, Data(("{\"links\":[" + dropboxLink + "],\"has_more\":true,\"cursor\":\"c1\"}").utf8))
        }
        let links = try await client(.dropbox).allPublicLinks()
        XCTAssertEqual(links.map(\.file.name), ["informe.pdf", "Fotos"])
        XCTAssertTrue(links[1].file.isFolder); XCTAssertNotNil(links[1].audience)
        XCTAssertEqual(json(seen[0].body).count, 0, "Sin ruta: todos los enlaces de la cuenta")
    }

    // MARK: - Box

    func testBoxKeepsOneLinkPerItemInItsOwnField() async throws {
        serve { method, _, body in
            if !body.contains("null") {
                return (200, Data(#"{"id":"9","shared_link":{"url":"https://app.box.com/s/x","access":"open","effective_access":"company","unshared_at":"2026-11-30T14:59:59-08:00","is_password_enabled":true,"permissions":{"can_download":false,"can_edit":false}}}"#.utf8))
            }
            return (200, Data(#"{"id":"9","shared_link":null}"#.utf8))
        }
        let api = client(.box)
        let links = try await api.publicLinks(for: item("9"))
        XCTAssertEqual(paths[0], "GET /2.0/files/9"); XCTAssertEqual(seen[0].query["fields"], "shared_link")
        XCTAssertEqual(links.count, 1)
        XCTAssertTrue(links[0].hasPassword); XCTAssertEqual(links[0].allowsDownload, false); XCTAssertEqual(links[0].expires, expiry)
        XCTAssertNotNil(links[0].audience, "La empresa limita el enlace aunque se pidiera abierto")

        _ = try await api.createPublicLink(for: item("9"), options: PublicLinkOptions(access: .edit, expires: expiry, password: "Secreta12", allowDownload: false))
        XCTAssertEqual(paths[1], "PUT /2.0/files/9")
        let link = try XCTUnwrap(json(seen[1].body)["shared_link"] as? [String: Any])
        XCTAssertEqual(link["access"] as? String, "open"); XCTAssertEqual(link["password"] as? String, "Secreta12")
        XCTAssertEqual(link["unshared_at"] as? String, "2026-11-30T22:59:59Z")
        XCTAssertEqual(link["permissions"] as? [String: Bool], ["can_download": false, "can_edit": true])

        try await api.revokePublicLink(links[0])
        XCTAssertEqual(paths[2], "PUT /2.0/files/9")
        XCTAssertTrue(seen[2].body.contains(#""shared_link":null"#), seen[2].body)
        do { _ = try await api.allPublicLinks(); XCTFail("Box no enumera enlaces") } catch { XCTAssertEqual(seen.count, 3) }
    }

    func testBoxPassesItsOwnReasonOn() async throws {
        serve { _, _, _ in (400, Data(#"{"type":"error","code":"bad_request","message":"Password does not meet minimum requirements"}"#.utf8)) }
        do { _ = try await client(.box).createPublicLink(for: item("9"), options: PublicLinkOptions(password: "corta")); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("minimum requirements"), error.localizedDescription) }
    }

    // MARK: - Nextcloud

    func testNextcloudCreatesTypeThreeSharesWithTheirSettings() async throws {
        serve { method, _, _ in
            switch method {
            case "GET":
                return (200, Data(#"{"ocs":{"meta":{"statuscode":200},"data":[{"id":7,"share_type":0,"share_with":"luis","path":"/Documentos/informe.pdf","item_type":"file","permissions":1},{"id":9,"share_type":3,"path":"/Documentos/informe.pdf","item_type":"file","permissions":3,"url":"https://n/s/x","expiration":"2026-11-30 00:00:00","password":"$2y$hash","hide_download":1}]}}"#.utf8))
            case "POST":
                return (200, Data(#"{"ocs":{"meta":{"statuscode":200},"data":{"id":10,"share_type":3,"path":"/Proyecto","item_type":"folder","permissions":15,"url":"https://n/s/y","expiration":"2026-11-30 00:00:00"}}}"#.utf8))
            default:
                return (200, Data(#"{"ocs":{"meta":{"statuscode":200},"data":[]}}"#.utf8))
            }
        }
        let api = client(.webdav, options: ["flavor": "nextcloud"])
        let links = try await api.publicLinks(for: item("/Documentos/informe.pdf"))
        XCTAssertEqual(seen[0].query["path"], "/Documentos/informe.pdf")
        XCTAssertEqual(links.map(\.handle), ["9"], "Compartir con una persona no es un enlace")
        XCTAssertEqual(links[0].access, .edit); XCTAssertTrue(links[0].hasPassword); XCTAssertEqual(links[0].allowsDownload, false)
        XCTAssertNotNil(links[0].expires)

        let created = try await api.createPublicLink(for: item("/Proyecto", folder: true), options: PublicLinkOptions(access: .edit, expires: expiry, password: "Secreta1", allowDownload: true))
        XCTAssertEqual(paths[1], "POST /ocs/v2.php/apps/files_sharing/api/v1/shares")
        for field in ["shareType=3", "permissions=15", "publicUpload=true", "password=Secreta1", "expireDate=" + LinkDates.day(expiry)] {
            XCTAssertTrue(seen[1].body.contains(field), "\(field) en \(seen[1].body)")
        }
        XCTAssertTrue(created.file.isFolder)

        try await api.revokePublicLink(links[0])
        XCTAssertEqual(paths[2], "DELETE /ocs/v2.php/apps/files_sharing/api/v1/shares/9")

        _ = try await api.allPublicLinks()
        XCTAssertNil(seen[3].query["path"]); XCTAssertEqual(seen[3].query["shared_with_me"], "false")
    }

    func testNextcloudRepeatsTheServersPolicy() async throws {
        serve { _, _, _ in (403, Data(#"{"ocs":{"meta":{"statuscode":403,"message":"Passwords are enforced for link and mail shares"},"data":[]}}"#.utf8)) }
        do { _ = try await client(.webdav, options: ["flavor": "nextcloud"]).createPublicLink(for: item("/a.pdf"), options: PublicLinkOptions()); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Passwords are enforced"), error.localizedDescription) }
    }

    // MARK: - Mega

    private let masterKey = Data((1...16).map(UInt8.init))
    private let fileKey = Data((1...32).map { UInt8($0 * 5 % 256) })
    private let folderKey = Data((1...16).map { UInt8($0 * 3) })
    private let shareKey = Data((40...55).map(UInt8.init))
    private func megaNode(_ handle: String, parent: String, kind: Int, name: String, key: Data) throws -> [String: Any] {
        let content = kind == 0 ? (MegaCrypto.unpack(fileKey: key)?.key ?? Data()) : key
        return ["h": handle, "p": parent, "t": kind, "ts": 1_700_000_000, "s": 10,
                "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": name], key: content)),
                "k": "PROPIA:" + MegaCrypto.encode(try MegaCrypto.ecb(key, key: masterKey, encrypt: true))]
    }
    private func megaClient() -> CloudAPI {
        let store = MemoryCredentials()
        store.stored["mega:ana@ejemplo.com"] = Credential(accessToken: "sesión", refreshToken: "", expires: .distantFuture, secret: MegaCrypto.encode(masterKey))
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        let account = Account(id: "mega:ana@ejemplo.com", cloud: .mega, name: "Mega", email: "ana@ejemplo.com", clientID: "", clientSecret: nil)
        return CloudAPI(account: account, session: URLSession(configuration: configuration), credentials: store)
    }

    func testMegaListsExportsFromTheTreeAndRevokesByRemovingThem() async throws {
        var commands: [[String: Any]] = []
        let tree: [[String: Any]] = [["h": "RAIZ", "p": "", "t": 2, "ts": 1_700_000_000],
                                     try megaNode("CARPETA", parent: "RAIZ", kind: 1, name: "Documentos", key: folderKey),
                                     try megaNode("ARCHIVO", parent: "CARPETA", kind: 0, name: "informe.pdf", key: fileKey),
                                     try megaNode("OTRA", parent: "RAIZ", kind: 1, name: "Fotos", key: folderKey)]
        let owned = [["h": "OTRA", "k": MegaCrypto.encode(try MegaCrypto.ecb(shareKey, key: masterKey, encrypt: true))]]
        let exported: [[String: Any]] = [["h": "ARCHIVO", "ph": "PUB1", "ets": 1_796_079_599], ["h": "OTRA", "ph": "PUB2", "down": 1], ["h": "BORRADO", "ph": "PUB3"]]
        StubProtocol.handler = { request in
            let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
            commands.append(command)
            if command["a"] as? String == "f" {
                return (200, [:], try JSONSerialization.data(withJSONObject: [["f": tree, "ok": owned, "ph": exported]]))
            }
            return (200, [:], Data("[0]".utf8))
        }
        let api = megaClient()
        let all = try await api.allPublicLinks()
        XCTAssertEqual(all.map(\.location), ["/Documentos/informe.pdf", "/Fotos"], "Un nodo que ya no existe no se lista")
        XCTAssertEqual(all[0].url?.absoluteString, "https://mega.nz/file/PUB1#" + MegaCrypto.encode(fileKey))
        XCTAssertEqual(all[0].expires, Date(timeIntervalSince1970: 1_796_079_599))
        XCTAssertEqual(all[1].url?.absoluteString, "https://mega.nz/folder/PUB2#" + MegaCrypto.encode(shareKey), "La carpeta abre con la clave de su compartición")
        XCTAssertNotNil(all[1].audience, "Un enlace retirado por Mega se dice")

        let file = CloudFile(id: "ARCHIVO", name: "informe.pdf", mime: "application/pdf", size: 10, modified: nil, webURL: nil, isFolder: false)
        let before = try await api.publicLinks(for: file)
        XCTAssertEqual(before.map(\.handle), ["ARCHIVO"])
        try await api.revokePublicLink(all[0])
        let revoke = try XCTUnwrap(commands.last)
        XCTAssertEqual(revoke["a"] as? String, "l"); XCTAssertEqual(revoke["n"] as? String, "ARCHIVO"); XCTAssertEqual(revoke["d"] as? Int, 1)
        let after = try await api.publicLinks(for: file)
        XCTAssertTrue(after.isEmpty, "El árbol se actualiza sin volver a pedirlo")
        XCTAssertEqual(commands.filter { $0["a"] as? String == "f" }.count, 1)
    }
}
