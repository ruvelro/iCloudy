import XCTest
@testable import iCloudy

/// O2 Cloud runs on Funambol OneMediaHub, whose API O2 does not document. These tests pin down what iCloudy sends and
/// what it makes of the answers, against a stand-in that replies the way the platform's own web client expects. They
/// cannot prove O2's servers behave like this; that is the part the experimental label is for.
@MainActor
final class O2CloudTests: XCTestCase {
    private var calls: [(path: String, action: String, query: [String: String], body: [String: Any])] = []
    /// Replies keyed by "path action", so a test only describes the answers it cares about.
    private var replies: [String: Any] = [:]
    private var rotateKeyOnce = false

    override func setUp() { calls = []; replies = [:]; rotateKeyOnce = false }
    override func tearDown() { StubProtocol.handler = nil }

    private func serve() {
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://cloud.o2online.es/")

            if url.path == "/sapi/login" {
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], Data(#"{"data":{"validationkey":"clave-1"}}"#.utf8))
            }
            if url.host == "descargas.ejemplo.com" { return (200, [:], Data("contenido descargado".utf8)) }

            let path = String(url.path.dropFirst("/sapi/".count))
            let action = query["action"] ?? ""
            let body = (try? JSONSerialization.jsonObject(with: requestData(request))) as? [String: Any] ?? [:]
            calls.append((path, action, query, (body["data"] as? [String: Any]) ?? body))

            // The platform rotates the key and hands the new one back inside the error.
            if rotateKeyOnce, query["validationkey"] == "clave-1" {
                rotateKeyOnce = false
                return (200, [:], Data(#"{"error":{"code":"SEC-1003","message":"stale","data":"clave-2"}}"#.utf8))
            }
            guard let reply = replies["\(path) \(action)"] else { return (200, [:], Data(#"{"data":{}}"#.utf8)) }
            return (200, [:], try JSONSerialization.data(withJSONObject: ["data": reply]))
        }
    }
    private func client() -> CloudAPI {
        let store = MemoryCredentials()
        store.stored["o2:cloud.o2online.es:ana@ejemplo.com"] = Credential(accessToken: "", refreshToken: "",
                                                                          expires: .distantFuture, secret: "contraseña")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let account = Account(id: "o2:cloud.o2online.es:ana@ejemplo.com", cloud: .o2, name: "O2 Cloud",
                              email: "ana@ejemplo.com", clientID: "", clientSecret: nil,
                              serverURL: "https://cloud.o2online.es", bookmark: nil,
                              options: ["host": "cloud.o2online.es"])
        return CloudAPI(account: account, session: URLSession(configuration: configuration), credentials: store)
    }
    private func withRoot() { replies["media/folder get"] = ["folders": [["id": 10, "name": "Mi nube"]]] }

    // MARK: - Signing in

    func testThePasswordTravelsInTheBodyAndNeverInTheAddress() async throws {
        var seen: URLRequest?
        StubProtocol.handler = { request in
            seen = request
            return (200, [:], Data(#"{"data":{"validationkey":"clave"}}"#.utf8))
        }
        defer { StubProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let state = try await O2API.signIn(host: "cloud.o2online.es", email: "ana@ejemplo.com", password: "secreta",
                                           session: URLSession(configuration: configuration))
        XCTAssertEqual(state.validationKey, "clave")
        let request = try XCTUnwrap(seen)
        XCTAssertEqual(request.url?.absoluteString, "https://cloud.o2online.es/sapi/login?action=login")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        let body = requestBody(request)
        XCTAssertTrue(body.contains("password=secreta"), body)
        XCTAssertTrue(body.contains("login=ana%40ejemplo.com"), body)
    }

    func testARejectedSignInSaysWhichPartWasWrong() async throws {
        StubProtocol.handler = { _ in (200, [:], Data(#"{"error":{"code":"SEC-1002","message":"Invalid credentials"}}"#.utf8)) }
        defer { StubProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        do {
            _ = try await O2API.signIn(host: "cloud.o2online.es", email: "ana@ejemplo.com", password: "mala",
                                       session: URLSession(configuration: configuration))
            XCTFail("Debe rechazar la contraseña")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("rechazó el correo o la contraseña"), error.localizedDescription)
        }
    }

    func testAnAccountWithTwoStepVerificationIsToldWhyItCannotContinue() async throws {
        StubProtocol.handler = { _ in (200, [:], Data(#"{"data":{"otprequired":true}}"#.utf8)) }
        defer { StubProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        do {
            _ = try await O2API.signIn(host: "cloud.o2online.es", email: "ana@ejemplo.com", password: "buena",
                                       session: URLSession(configuration: configuration))
            XCTFail("Sin clave de validación no hay sesión")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("verificación en dos pasos"), error.localizedDescription)
        }
    }

    // MARK: - Identifiers

    func testFolderAndFileNumbersNeverGetConfused() throws {
        // Funambol numbers folders and media separately, so a bare "12" would be ambiguous.
        let folder = CloudAPI.o2FolderID("12")
        let file = CloudAPI.o2MediaID("12", kind: .picture)
        XCTAssertNotEqual(folder, file)
        XCTAssertNil(try XCTUnwrap(CloudAPI.o2Split(folder)).kind)
        XCTAssertEqual(try XCTUnwrap(CloudAPI.o2Split(folder)).value, "12")
        XCTAssertEqual(try XCTUnwrap(CloudAPI.o2Split(file)).kind, .picture)
        XCTAssertEqual(try XCTUnwrap(CloudAPI.o2Split(file)).value, "12")
        XCTAssertNil(CloudAPI.o2Split("12"), "Un identificador sin prefijo no se acepta a ciegas")
        XCTAssertNil(CloudAPI.o2Split("m:inventado:12"))
    }

    func testTheMediaKindFallsBackToTheContentTypeWhenTheServerOmitsIt() {
        XCTAssertEqual(O2MediaKind.of(["mediatype": "video"]), .video)
        XCTAssertEqual(O2MediaKind.of(["contenttype": "image/jpeg"]), .picture)
        XCTAssertEqual(O2MediaKind.of(["contenttype": "audio/mpeg"]), .audio)
        XCTAssertEqual(O2MediaKind.of(["contenttype": "application/pdf"]), .file)
        XCTAssertEqual(O2MediaKind.of([:]), .file)
        XCTAssertEqual(O2MediaKind.of(["mediatype": "picture", "contenttype": "video/mp4"]), .picture,
                       "Lo que dice el servidor manda sobre la deducción")
    }

    // MARK: - Browsing

    func testAListingJoinsFoldersAndFilesFromTheirOwnEndpoints() async throws {
        serve(); withRoot()
        replies["media/folder list"] = ["folders": [["id": 21, "name": "Facturas", "modificationdate": "20240115T101530Z"]]]
        replies["media get"] = ["more": false, "media": [
            ["id": 31, "name": "recibo.pdf", "size": 1234, "contenttype": "application/pdf",
             "mediatype": "file", "modificationdate": "20240116T090000Z"],
            ["id": 32, "name": "foto.jpg", "size": 90, "contenttype": "image/jpeg"]]]

        let files = try await client().list(parent: "root")
        XCTAssertEqual(files.map(\.name), ["Facturas", "foto.jpg", "recibo.pdf"], "Carpetas primero, luego por nombre")
        let folder = try XCTUnwrap(files.first)
        XCTAssertTrue(folder.isFolder)
        XCTAssertNil(folder.size)
        XCTAssertEqual(folder.modified, ISO8601DateFormatter().date(from: "2024-01-15T10:15:30Z"))
        let receipt = try XCTUnwrap(files.first { $0.name == "recibo.pdf" })
        XCTAssertEqual(receipt.size, 1234)
        XCTAssertEqual(receipt.mime, "application/pdf")
        XCTAssertEqual(receipt.id, CloudAPI.o2MediaID("31", kind: .file))
        // The picture had no media type of its own, so its content type placed it.
        XCTAssertEqual(try XCTUnwrap(files.first { $0.name == "foto.jpg" }).id, CloudAPI.o2MediaID("32", kind: .picture))

        let listing = calls.first { $0.path == "media/folder" && $0.action == "list" }
        XCTAssertEqual(listing?.query["parentid"], "10", "Se pide dentro de la raíz que devolvió el servidor")
        XCTAssertEqual(listing?.query["limit"], "200")
        let media = calls.first { $0.path == "media" && $0.action == "get" }
        XCTAssertEqual(media?.query["folderid"], "10")
        XCTAssertEqual(media?.body["fields"] as? [String], O2API.mediaFields)
    }

    func testBothListingsArePagedUntilTheServerRunsOut() async throws {
        serve(); withRoot()
        var folderPages = 0
        var mediaPages = 0
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            if url.path == "/sapi/login" { return (200, [:], Data(#"{"data":{"validationkey":"clave-1"}}"#.utf8)) }
            if query["action"] == "get", url.path == "/sapi/media/folder" {
                return (200, [:], try JSONSerialization.data(withJSONObject: ["data": ["folders": [["id": 10, "name": "raíz"]]]]))
            }
            if url.path == "/sapi/media/folder" {
                folderPages += 1
                // A full page means there may be more; a short one ends it.
                let names = folderPages == 1 ? (1...200).map { "carpeta \($0)" } : ["última"]
                let folders = names.enumerated().map { ["id": $0.offset + folderPages * 1000, "name": $0.element] }
                return (200, [:], try JSONSerialization.data(withJSONObject: ["data": ["folders": folders]]))
            }
            mediaPages += 1
            let more = mediaPages == 1
            let media = [["id": mediaPages, "name": "archivo \(mediaPages).txt", "size": 1]]
            return (200, [:], try JSONSerialization.data(withJSONObject: ["data": ["more": more, "media": media]]))
        }
        let files = try await client().list(parent: "root")
        XCTAssertEqual(folderPages, 2, "La primera página venía llena, así que se pide otra")
        XCTAssertEqual(mediaPages, 2, "El servidor avisó de que había más")
        XCTAssertEqual(files.filter(\.isFolder).count, 201)
        XCTAssertEqual(files.filter { !$0.isFolder }.count, 2)
    }

    func testBreadcrumbsWalkUpToTheRootAndStopThere() async throws {
        serve()
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/sapi/login" { return (200, [:], Data(#"{"data":{"validationkey":"clave-1"}}"#.utf8)) }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            guard let id = query["id"] else {
                return (200, [:], try JSONSerialization.data(withJSONObject: ["data": ["folders": [["id": 10, "name": "raíz"]]]]))
            }
            let tree = ["21": ("Facturas", 10), "22": ("2024", 21)]
            let node = try XCTUnwrap(tree[id])
            return (200, [:], try JSONSerialization.data(withJSONObject: [
                "data": ["folders": [["id": Int(id)!, "name": node.0, "parentid": node.1]]]]))
        }
        let trail = try await client().folderTrail(id: CloudAPI.o2FolderID("22"))
        XCTAssertEqual(trail.map(\.name), ["Facturas", "2024"], "De fuera hacia dentro, sin incluir la raíz")
    }

    func testQuotaReportsTheRealLimitAndTheUnlimitedCase() async throws {
        serve(); withRoot()
        replies["media get-storage-space"] = ["used": 40, "quota": 100, "nolimit": false]
        let quota = try await client().storageQuota()
        XCTAssertEqual(quota.used, 40)
        XCTAssertEqual(quota.total, 100)

        replies["media get-storage-space"] = ["used": 40, "quota": 100, "nolimit": true]
        let unlimited = try await client().storageQuota()
        XCTAssertNil(unlimited.total, "Una cuenta sin límite no inventa un tope")
        XCTAssertEqual(unlimited.used, 40)
    }

    // MARK: - Changing things

    func testRenamingUsesADifferentEndpointForFoldersAndForFiles() async throws {
        serve(); withRoot()
        let api = client()
        let folder = CloudFile(id: CloudAPI.o2FolderID("21"), name: "Facturas",
                               mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        try await api.rename(file: folder, name: "Recibos")
        let folderCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(folderCall.path, "media/folder")
        XCTAssertEqual(folderCall.action, "save")
        XCTAssertEqual(folderCall.body["id"] as? String, "21")
        XCTAssertEqual(folderCall.body["name"] as? String, "Recibos")

        let picture = CloudFile(id: CloudAPI.o2MediaID("31", kind: .picture), name: "foto.jpg", mime: "image/jpeg",
                                size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.rename(file: picture, name: "playa.jpg")
        let fileCall = try XCTUnwrap(calls.last)
        XCTAssertEqual(fileCall.path, "upload/picture", "El tipo de medio decide el punto final")
        XCTAssertEqual(fileCall.action, "save-metadata")
        XCTAssertEqual(fileCall.body["name"] as? String, "playa.jpg")
    }

    func testMovingAFileChangesItsFolderAndMovingAFolderChangesItsParent() async throws {
        serve(); withRoot()
        let api = client()
        let file = CloudFile(id: CloudAPI.o2MediaID("31", kind: .file), name: "recibo.pdf", mime: "application/pdf",
                             size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.move(file: file, to: CloudAPI.o2FolderID("21"))
        var call = try XCTUnwrap(calls.last)
        XCTAssertEqual(call.path, "upload/file")
        XCTAssertEqual(call.body["folderid"] as? String, "21")

        let folder = CloudFile(id: CloudAPI.o2FolderID("22"), name: "2024", mime: "application/vnd.google-apps.folder",
                               size: nil, modified: nil, webURL: nil, isFolder: true)
        try await api.move(file: folder, to: "root")
        call = try XCTUnwrap(calls.last)
        XCTAssertEqual(call.path, "media/folder")
        XCTAssertEqual(call.body["parentid"] as? String, "10")
        XCTAssertEqual(call.body["name"] as? String, "2024", "Guardar la carpeta exige mandar también su nombre")
    }

    func testDeletingIsASoftDeleteSoTheBinKeepsTheItem() async throws {
        serve(); withRoot()
        let api = client()
        let video = CloudFile(id: CloudAPI.o2MediaID("40", kind: .video), name: "clip.mp4", mime: "video/mp4",
                              size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.trash(file: video)
        var call = try XCTUnwrap(calls.last)
        XCTAssertEqual(call.path, "media/video")
        XCTAssertEqual(call.action, "delete")
        XCTAssertEqual(call.query["softdelete"], "true", "Un borrado definitivo no sería reversible")
        XCTAssertEqual(call.body["videos"] as? [String], ["40"])

        let folder = CloudFile(id: CloudAPI.o2FolderID("21"), name: "Facturas", mime: "application/vnd.google-apps.folder",
                               size: nil, modified: nil, webURL: nil, isFolder: true)
        try await api.trash(file: folder)
        call = try XCTUnwrap(calls.last)
        XCTAssertEqual(call.path, "media/folder")
        XCTAssertEqual(call.action, "softdelete")
        XCTAssertEqual(call.body["folders"] as? [String], ["21"])
    }

    func testARotatedKeyIsPickedUpAndTheCallRetriedOnce() async throws {
        serve(); withRoot()
        replies["media get-storage-space"] = ["used": 1, "quota": 2, "nolimit": false]
        rotateKeyOnce = true
        let quota = try await client().storageQuota()
        XCTAssertEqual(quota.used, 1, "La llamada se rehace sola con la clave nueva")
        let attempts = calls.filter { $0.action == "get-storage-space" }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.first?.query["validationkey"], "clave-1")
        XCTAssertEqual(attempts.last?.query["validationkey"], "clave-2", "La clave nueva venía dentro del error")
    }

    // MARK: - Contents

    func testDownloadingAsksForTheAddressAndThenFetchesIt() async throws {
        serve(); withRoot()
        replies["media get"] = ["media": [["id": 31, "name": "recibo.pdf", "url": "https://descargas.ejemplo.com/31"]]]
        let file = CloudFile(id: CloudAPI.o2MediaID("31", kind: .file), name: "recibo.pdf", mime: "application/pdf",
                             size: 20, modified: nil, webURL: nil, isFolder: false)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var reported: Int64 = 0
        try await client().download(file: file, to: destination) { sent, _ in reported = sent }
        XCTAssertEqual(try Data(contentsOf: destination), Data("contenido descargado".utf8))
        XCTAssertEqual(reported, 20)
        let ask = try XCTUnwrap(calls.first { $0.path == "media" && $0.action == "get" })
        XCTAssertEqual(ask.body["ids"] as? [String], ["31"])
        XCTAssertEqual(ask.body["fields"] as? [String], ["url", "name", "size"])
    }

    func testAnUploadSendsTheMetadataAndTheBytesInOneRequest() async throws {
        serve(); withRoot()
        var uploaded: Data?
        var contentType: String?
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            if url.path == "/sapi/login" { return (200, [:], Data(#"{"data":{"validationkey":"clave-1"}}"#.utf8)) }
            if url.path == "/sapi/upload" {
                uploaded = requestData(request)
                contentType = request.value(forHTTPHeaderField: "Content-Type")
                return (200, [:], Data(#"{"data":{"id":77}}"#.utf8))
            }
            return (200, [:], try JSONSerialization.data(withJSONObject: ["data": ["folders": [["id": 10, "name": "raíz"]]]]))
        }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("bytes del archivo".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let checkpoint = UploadCheckpoint(total: 17, modified: stamp)

        let receipt = try await client().resumableUpload(local: source, parent: "root", name: "nota.txt", replacing: nil,
                                                         checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, CloudAPI.o2MediaID("77", kind: .file))
        XCTAssertEqual(receipt.verification, .unavailable, "La plataforma no informa de ninguna suma que comparar")

        let body = String(decoding: try XCTUnwrap(uploaded), as: UTF8.self)
        XCTAssertTrue(try XCTUnwrap(contentType).hasPrefix("multipart/form-data; boundary="), contentType ?? "")
        XCTAssertTrue(body.contains("name=\"data\""), "Los metadatos van en su propia parte")
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"nota.txt\""))
        XCTAssertTrue(body.contains("\"folderid\":\"10\""), body.prefix(400).description)
        XCTAssertTrue(body.contains("\"size\":17"))
        XCTAssertTrue(body.contains("bytes del archivo"), "Y el contenido va entero en la misma petición")
    }

    func testSharingWorksForFoldersAndSaysSoForFiles() async throws {
        serve(); withRoot()
        replies["link/folder save"] = ["url": "https://cloud.o2online.es/link/abc123"]
        let api = client()
        let folder = CloudFile(id: CloudAPI.o2FolderID("21"), name: "Facturas", mime: "application/vnd.google-apps.folder",
                               size: nil, modified: nil, webURL: nil, isFolder: true)
        let link = try await api.publicLink(for: folder)
        XCTAssertEqual(link.absoluteString, "https://cloud.o2online.es/link/abc123")
        XCTAssertEqual(calls.last?.body["folderid"] as? String, "21")

        let file = CloudFile(id: CloudAPI.o2MediaID("31", kind: .file), name: "recibo.pdf", mime: "application/pdf",
                             size: 1, modified: nil, webURL: nil, isFolder: false)
        do { _ = try await api.publicLink(for: file); XCTFail("Un archivo suelto no tiene enlace aquí") }
        catch { XCTAssertTrue(error.localizedDescription.contains("enlaces de carpetas"), error.localizedDescription) }
    }

    func testCapabilitiesSayWhatThePlatformCanAndCannotDo() {
        let o2 = Cloud.o2.capabilities
        XCTAssertTrue(o2.quota)
        XCTAssertTrue(o2.publicLinks)
        XCTAssertTrue(o2.reversibleTrash, "El borrado es suave y la papelera de O2 lo conserva")
        XCTAssertFalse(o2.search, "La plataforma no expone búsqueda de archivos a otras aplicaciones")
        XCTAssertFalse(o2.copy)
        XCTAssertFalse(o2.checksum)
        XCTAssertFalse(o2.oauth)
        XCTAssertTrue(Cloud.o2.isExperimental)
        XCTAssertTrue(Cloud.o2.usesPasswordLogin)
        XCTAssertFalse(Cloud.o2.isSelfHosted, "El servidor es de O2, no del usuario, aunque se pueda cambiar")
    }
}
