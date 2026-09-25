import XCTest
@testable import iCloudy

/// Sharing with named people, provider by provider: what is sent, what comes back, and what can be taken away.
@MainActor
final class SharingTests: XCTestCase {
    private var seen: [(method: String, path: String, query: [String: String], body: String)] = []
    override func setUp() { seen = [] }
    override func tearDown() { StubProtocol.handler = nil }

    private func client(_ cloud: Cloud, options: [String: String] = [:]) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test", cloud: cloud, name: "Test", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: cloud == .webdav ? "https://nube.example.com/remote.php/dav/files/ana" : nil, bookmark: nil, options: options)
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func item(_ id: String, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: "informe.pdf", mime: folder ? "application/vnd.google-apps.folder" : "application/pdf", size: 1, modified: nil, webURL: nil, isFolder: folder)
    }
    private func serve(_ answer: @escaping (String, String, String) -> (Int, Data)) {
        StubProtocol.handler = { [self] request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let body = requestBody(request)
            seen.append((request.httpMethod ?? "", parts.path, query, body))
            let (status, data) = answer(request.httpMethod ?? "", parts.path, body)
            return (status, [:], data)
        }
    }
    private var paths: [String] { seen.map { "\($0.method) \($0.path)" } }

    func testOnlyTheProvidersWithAPeopleAPIOfferIt() {
        for cloud in [Cloud.google, .microsoft, .dropbox, .box] { XCTAssertTrue(cloud.capabilities.memberSharing, "\(cloud)") }
        for cloud in [Cloud.ftp, .sftp, .volume, .mega, .o2, .webdav] { XCTAssertFalse(cloud.capabilities.memberSharing, "\(cloud)") }
        var nextcloud = Account(id: "w", cloud: .webdav, name: "", email: "", clientID: "", clientSecret: nil, serverURL: "https://n.example.com/remote.php/dav/files/a")
        nextcloud.options["flavor"] = "nextcloud"
        XCTAssertTrue(nextcloud.capabilities.memberSharing, "La API OCS de Nextcloud sí comparte con personas")
        XCTAssertTrue(Account.demo.capabilities.memberSharing)
        XCTAssertTrue(SharingView.plausible("ana@example.com", cloud: .google))
        XCTAssertFalse(SharingView.plausible("ana@", cloud: .google))
        XCTAssertFalse(SharingView.plausible("ana example.com", cloud: .google))
        XCTAssertTrue(SharingView.plausible("ana", cloud: .webdav), "En Nextcloud un nombre de usuario vale")
        XCTAssertFalse(SharingView.plausible("ana", cloud: .box))
    }

    func testDriveListsGrantsWithTheirLevelsAndSharesByPermission() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"permissions":[{"id":"p0","type":"user","role":"owner","emailAddress":"ana@example.com","displayName":"Ana"},{"id":"p1","type":"user","role":"commenter","emailAddress":"luis@example.com"},{"id":"p2","type":"anyone","role":"reader"},{"id":"p3","type":"group","role":"writer","emailAddress":"equipo@example.com","displayName":"Equipo"}]}"#.utf8))
            }
            return (method == "DELETE" ? 204 : 200, Data((method == "DELETE" ? "" : #"{"id":"p9"}"#).utf8))
        }
        let api = client(.google)
        let grants = try await api.permissions(for: item("f1"))
        XCTAssertEqual(grants.map(\.id), ["p0", "p1", "p2", "p3"])
        XCTAssertTrue(grants[0].isOwner); XCTAssertNil(grants[0].role); XCTAssertFalse(grants[0].canRevoke)
        XCTAssertEqual(grants[1].role, .viewer, "Comentar se muestra como ver")
        XCTAssertEqual(grants[2].kind, .link); XCTAssertEqual(grants[2].name, "Cualquiera con el enlace")
        XCTAssertEqual(grants[3].kind, .group); XCTAssertEqual(grants[3].role, .editor)

        try await api.share(file: item("f1"), with: "eva@example.com", role: .editor)
        XCTAssertEqual(paths[1], "POST /drive/v3/files/f1/permissions")
        XCTAssertEqual(seen[1].query["sendNotificationEmail"], "true")
        XCTAssertTrue(seen[1].body.contains(#""role":"writer""#) && seen[1].body.contains(#""type":"user""#) && seen[1].body.contains("eva@example.com"), seen[1].body)

        try await api.revoke(grants[1], from: item("f1"))
        XCTAssertEqual(paths[2], "DELETE /drive/v3/files/f1/permissions/p1")
    }

    func testOneDriveInvitesAndReadsLinksAndPeopleApart() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"value":[{"id":"a","roles":["owner"],"grantedToV2":{"user":{"displayName":"Ana","email":"ana@example.com"}}},{"id":"b","roles":["write"],"grantedToIdentitiesV2":[{"user":{"displayName":"Luis","email":"luis@example.com"}}]},{"id":"c","roles":["read"],"link":{"scope":"anonymous","type":"view"}},{"id":"d","roles":["read"],"inheritedFrom":{"id":"parent"},"grantedToV2":{"user":{"displayName":"Eva"}}}]}"#.utf8))
            }
            if path.hasSuffix("/invite") { return (200, Data(#"{"value":[{"id":"n","roles":["read"]}]}"#.utf8)) }
            return (204, Data())
        }
        let api = client(.microsoft)
        let grants = try await api.permissions(for: item("X"))
        XCTAssertEqual(grants.map(\.id), ["a", "b", "c", "d"])
        XCTAssertTrue(grants[0].isOwner)
        XCTAssertEqual(grants[1].role, .editor); XCTAssertEqual(grants[1].email, "luis@example.com")
        XCTAssertEqual(grants[2].kind, .link)
        XCTAssertTrue(grants[3].isInherited); XCTAssertFalse(grants[3].canRevoke, "Lo heredado se quita en la carpeta padre")

        try await api.share(file: item("X"), with: "eva@example.com", role: .viewer)
        XCTAssertEqual(paths[1], "POST /v1.0/me/drive/items/X/invite")
        XCTAssertTrue(seen[1].body.contains(#""roles":["read"]"#) && seen[1].body.contains(#""requireSignIn":true"#), seen[1].body)
        try await api.revoke(grants[1], from: item("X"))
        XCTAssertEqual(paths[2], "DELETE /v1.0/me/drive/items/X/permissions/b")
    }

    func testBoxUsesCollaborationsOnTheItemsOwnRoute() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"entries":[{"id":"c1","role":"owner","accessible_by":{"type":"user","name":"Ana","login":"ana@example.com"}},{"id":"c2","role":"viewer uploader","accessible_by":{"type":"user","name":"Luis","login":"luis@example.com"}},{"id":"c3","role":"viewer","status":"pending","invite_email":"eva@example.com"}]}"#.utf8))
            }
            return (method == "DELETE" ? 204 : 201, Data((method == "DELETE" ? "" : #"{"id":"c4"}"#).utf8))
        }
        let api = client(.box)
        let grants = try await api.permissions(for: item("9", folder: true))
        XCTAssertEqual(paths[0], "GET /2.0/folders/9/collaborations")
        XCTAssertTrue(grants[0].isOwner)
        XCTAssertEqual(grants[1].role, .editor, "Los roles que suben algo se muestran como editar")
        XCTAssertEqual(grants[2].kind, .pending); XCTAssertEqual(grants[2].email, "eva@example.com")

        try await api.share(file: item("9", folder: true), with: "eva@example.com", role: .viewer)
        XCTAssertEqual(paths[1], "POST /2.0/collaborations")
        XCTAssertEqual(seen[1].query["notify"], "true")
        XCTAssertTrue(seen[1].body.contains(#""type":"folder""#) && seen[1].body.contains(#""login":"eva@example.com""#), seen[1].body)
        try await api.revoke(grants[1], from: item("9", folder: true))
        XCTAssertEqual(paths[2], "DELETE /2.0/collaborations/c2")
    }

    func testDropboxSharesFilesDirectlyAndTurnsAFolderIntoASharedFolderFirst() async throws {
        serve { _, path, body in
            switch path {
            case "/2/sharing/list_file_members":
                return (200, Data(#"{"users":[{"access_type":{".tag":"owner"},"user":{"display_name":"Ana","email":"ana@example.com","account_id":"dbid:1"}},{"access_type":{".tag":"editor"},"user":{"display_name":"Luis","email":"luis@example.com","account_id":"dbid:2"},"is_inherited":false}],"invitees":[{"access_type":{".tag":"viewer"},"invitee":{".tag":"email","email":"eva@example.com"}}],"groups":[]}"#.utf8))
            case "/2/files/get_metadata":
                return (200, Data((body.contains("compartida") ? #"{"name":"Compartida","sharing_info":{"shared_folder_id":"sf1"}}"# : #"{"name":"Nueva"}"#).utf8))
            case "/2/sharing/share_folder":
                return (200, Data(#"{".tag":"complete","shared_folder_id":"sf2"}"#.utf8))
            case "/2/sharing/list_folder_members":
                return (200, Data(#"{"users":[],"groups":[{"access_type":{".tag":"viewer"},"group":{"group_name":"Diseño","group_id":"g1"}}],"invitees":[]}"#.utf8))
            default:
                return (200, Data("{}".utf8))
            }
        }
        let api = client(.dropbox)
        let grants = try await api.permissions(for: item("/informe.pdf"))
        XCTAssertEqual(grants.map(\.kind), [.person, .person, .pending])
        XCTAssertTrue(grants[0].isOwner); XCTAssertEqual(grants[1].role, .editor)

        try await api.share(file: item("/informe.pdf"), with: "eva@example.com", role: .viewer)
        XCTAssertEqual(paths.last, "POST /2/sharing/add_file_member")
        XCTAssertTrue(seen.last!.body.contains(#""access_level":"viewer""#), seen.last!.body)
        try await api.revoke(grants[1], from: item("/informe.pdf"))
        XCTAssertEqual(paths.last, "POST /2/sharing/remove_file_member_2")
        XCTAssertTrue(seen.last!.body.contains("luis@example.com"))

        seen.removeAll()
        let folderGrants = try await api.permissions(for: item("/compartida", folder: true))
        XCTAssertEqual(paths, ["POST /2/files/get_metadata", "POST /2/sharing/list_folder_members"])
        XCTAssertEqual(folderGrants.first?.kind, .group)
        seen.removeAll()
        try await api.share(file: item("/nueva", folder: true), with: "eva@example.com", role: .editor)
        XCTAssertEqual(paths, ["POST /2/files/get_metadata", "POST /2/sharing/share_folder", "POST /2/sharing/add_folder_member"], "Una carpeta sin compartir se comparte primero")
        XCTAssertTrue(seen[2].body.contains(#""shared_folder_id":"sf2""#) && seen[2].body.contains(#""access_level":"editor""#), seen[2].body)
        seen.removeAll()
        let none = try await api.permissions(for: item("/nueva", folder: true))
        XCTAssertTrue(none.isEmpty, "Listar no convierte la carpeta en compartida")
        XCTAssertEqual(paths, ["POST /2/files/get_metadata"])
    }

    func testNextcloudSharesThroughOCSWithTheRightBitsAndKind() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"ocs":{"meta":{"statuscode":200},"data":[{"id":7,"share_type":0,"share_with":"luis","share_with_displayname":"Luis","permissions":31},{"id":8,"share_type":4,"share_with":"eva@example.com","permissions":1},{"id":9,"share_type":3,"permissions":1,"url":"https://n/s/x"}]}}"#.utf8))
            }
            if method == "DELETE" { return (200, Data(#"{"ocs":{"meta":{"statuscode":200},"data":[]}}"#.utf8)) }
            return (200, Data(#"{"ocs":{"meta":{"statuscode":200},"data":{"id":10}}}"#.utf8))
        }
        let api = client(.webdav, options: ["flavor": "nextcloud"])
        let grants = try await api.permissions(for: item("/Documentos/informe.pdf"))
        XCTAssertEqual(seen[0].path, "/ocs/v2.php/apps/files_sharing/api/v1/shares")
        XCTAssertEqual(seen[0].query["path"], "/Documentos/informe.pdf")
        XCTAssertEqual(grants.map(\.role), [.editor, .viewer, .viewer])
        XCTAssertEqual(grants.map(\.kind), [.person, .person, .link])
        XCTAssertEqual(grants[1].email, "eva@example.com"); XCTAssertNil(grants[0].email, "Un usuario del servidor no es un correo")

        try await api.share(file: item("/Documentos", folder: true), with: "luis", role: .editor)
        XCTAssertTrue(seen[1].body.contains("shareType=0") && seen[1].body.contains("permissions=15"), seen[1].body)
        try await api.share(file: item("/Documentos/informe.pdf"), with: "eva@example.com", role: .editor)
        XCTAssertTrue(seen[2].body.contains("shareType=4") && seen[2].body.contains("permissions=3"), "Un archivo editable es leer y actualizar: \(seen[2].body)")
        try await api.revoke(grants[0], from: item("/Documentos/informe.pdf"))
        XCTAssertEqual(paths[3], "DELETE /ocs/v2.php/apps/files_sharing/api/v1/shares/7")
        XCTAssertEqual(WebDAVProvider.nextcloudPermissions(.viewer, folder: true), 1)

        let plain = client(.webdav)
        do { _ = try await plain.permissions(for: item("/x")); XCTFail("WebDAV a secas no tiene API de compartición") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Nextcloud"), error.localizedDescription) }
    }

    func testTheDemoKeepsGrantsForTheRunAndAlwaysShowsTheOwner() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-compartir-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let demo = try DemoStore(directory: directory)
        let id = try demo.add(name: "nota.txt", parent: "root", content: Data("x".utf8))
        XCTAssertEqual(try demo.permissions(id).map(\.isOwner), [true])
        try demo.share(id, with: "eva@example.com", role: .editor)
        try demo.share(id, with: "eva@example.com", role: .viewer)
        let grants = try demo.permissions(id)
        XCTAssertEqual(grants.count, 2, "Compartir dos veces con la misma persona cambia el nivel, no duplica")
        XCTAssertEqual(grants[1].role, .viewer)
        try demo.revoke("eva@example.com", from: id)
        XCTAssertEqual(try demo.permissions(id).count, 1)
    }
}
