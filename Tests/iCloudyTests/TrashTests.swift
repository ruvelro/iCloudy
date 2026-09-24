import XCTest
@testable import iCloudy

/// Binning used to be a one-way door: the app could send things to a provider's bin and then only point at its
/// website. These cover the way back and the way out, provider by provider: listing, restoring, purging, emptying.
@MainActor
final class TrashTests: XCTestCase {
    /// Every request the stub saw: method, path, query and body, in order.
    private var seen: [(method: String, path: String, query: [String: String], body: String)] = []

    override func setUp() { seen = [] }
    override func tearDown() { StubProtocol.handler = nil }

    private func client(_ cloud: Cloud, options: [String: String] = [:]) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: options)
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func item(_ id: String, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: "cosa", mime: folder ? "application/vnd.google-apps.folder" : "text/plain", size: 1, modified: nil, webURL: nil, isFolder: folder)
    }
    /// Records the request and lets the test answer by method and path.
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

    // MARK: - What each provider declares

    func testTheTrashTabAppearsOnlyWhereTheProviderCanListIt() {
        let drive = Account(id: "g", cloud: .google, name: "", email: "", clientID: "", clientSecret: nil)
        XCTAssertTrue(AppModel.collections(for: drive).contains(.trash), "Drive lista su papelera")
        XCTAssertTrue(AppModel.collections(for: Account.demo).contains(.trash), "La demo también, para probar la pestaña sin cuenta")
        for cloud in [Cloud.ftp, .webdav] {
            let account = Account(id: cloud.rawValue, cloud: cloud, name: "", email: "", clientID: "", clientSecret: nil, serverURL: "https://x.example.com/")
            XCTAssertFalse(AppModel.collections(for: account).contains(.trash), "\(cloud) no tiene papelera que listar")
            XCTAssertFalse(cloud.capabilities.permanentDelete, "Donde borrar ya es definitivo no hay nada más definitivo que ofrecer")
        }
        XCTAssertFalse(Cloud.microsoft.capabilities.trashListing, "Graph no expone la papelera de reciclaje")
        XCTAssertTrue(Cloud.microsoft.capabilities.permanentDelete, "Pero sí borra sin pasar por ella")
        XCTAssertFalse(Cloud.volume.capabilities.trashListing, "La papelera del Finder no se lee desde el sandbox")
        XCTAssertTrue(Cloud.volume.capabilities.permanentDelete)
        XCTAssertFalse(Cloud.dropbox.capabilities.emptyTrash, "Dropbox no tiene vaciado; sus borrados caducan solos")
        XCTAssertTrue(Cloud.mega.capabilities.emptyTrash)
        XCTAssertTrue(Cloud.box.capabilities.emptyTrash)
        XCTAssertTrue(Collection.virtualRoots.contains(Collection.trash.rootID), "La papelera no es una carpeta real")
    }

    // MARK: - Google Drive

    func testDriveListsWhatWasBinnedByItselfAndClearsTheFlagToRestore() async throws {
        serve { method, path, _ in
            if method == "GET" {
                return (200, Data(#"{"files":[{"id":"a","name":"suelto.txt","mimeType":"text/plain","explicitlyTrashed":true},{"id":"b","name":"hijo.txt","mimeType":"text/plain","explicitlyTrashed":false}]}"#.utf8))
            }
            return (method == "DELETE" ? 204 : 200, Data((method == "DELETE" ? "" : #"{"id":"a"}"#).utf8))
        }
        let api = client(.google)
        let listed = try await api.list(parent: Collection.trash.rootID)
        XCTAssertEqual(seen[0].query["q"], "trashed = true")
        XCTAssertTrue(seen[0].query["fields"]?.contains("explicitlyTrashed") == true)
        XCTAssertEqual(listed.map(\.id), ["a"], "Lo que cayó con su carpeta no se lista aparte, como en la web de Drive")

        try await api.restore(file: item("a"))
        XCTAssertEqual(seen[1].method, "PATCH")
        XCTAssertTrue(seen[1].body.contains(#""trashed":false"#), seen[1].body)

        try await api.deletePermanently(file: item("a"))
        XCTAssertEqual(paths[2], "DELETE /drive/v3/files/a")

        try await api.emptyTrash()
        XCTAssertEqual(paths[3], "DELETE /drive/v3/files/trash")
        XCTAssertNil(seen[3].query["driveId"], "Mi unidad no lleva identificador")
    }

    func testDriveEmptiesASharedDrivesOwnBin() async throws {
        serve { _, _, _ in (204, Data()) }
        try await client(.google, options: ["driveID": "0AB"]).emptyTrash()
        XCTAssertEqual(seen[0].query["driveId"], "0AB")
    }

    // MARK: - OneDrive

    func testOneDriveDeletesForGoodWithPermanentDeleteAndExplainsARefusal() async throws {
        var status = 204
        serve { _, _, _ in (status, status == 204 ? Data() : Data(#"{"error":{"code":"notAllowed","message":"Not supported"}}"#.utf8)) }
        let api = client(.microsoft)
        try await api.deletePermanently(file: item("X1"))
        XCTAssertEqual(paths, ["POST /v1.0/me/drive/items/X1/permanentDelete"])
        status = 403
        do {
            try await api.deletePermanently(file: item("X1"))
            XCTFail("Se esperaba un rechazo explicado")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no admite el borrado definitivo"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("Not supported"), "El motivo del proveedor se conserva")
        }
    }

    // MARK: - Box

    func testBoxListsTheTrashFolderRestoresInPlaceAndPurgesInTwoSteps() async throws {
        serve { method, path, _ in
            if path.hasSuffix("/trash/items") { return (200, Data(#"{"entries":[{"id":"7","type":"file","name":"viejo.pdf"}]}"#.utf8)) }
            if method == "GET" { return (200, Data(#"{"item_status":"active"}"#.utf8)) }
            if method == "DELETE" { return (204, Data()) }
            return (201, Data(#"{"id":"7"}"#.utf8))
        }
        let api = client(.box)
        let listed = try await api.list(parent: Collection.trash.rootID)
        XCTAssertEqual(paths[0], "GET /2.0/folders/trash/items")
        XCTAssertEqual(listed.map(\.name), ["viejo.pdf"])

        try await api.restore(file: item("7"))
        XCTAssertEqual(paths[1], "POST /2.0/files/7", "Restaurar es un POST vacío al elemento")

        // Still in the tree: Box only purges what is already in the trash, so it is binned first.
        try await api.deletePermanently(file: item("7"))
        XCTAssertEqual(Array(paths[2...]), ["GET /2.0/files/7", "DELETE /2.0/files/7", "DELETE /2.0/files/7/trash"])
        seen.removeAll()

        try await api.emptyTrash()
        XCTAssertEqual(paths, ["GET /2.0/folders/trash/items", "DELETE /2.0/files/7/trash"], "Sin llamada única de vaciado: se recorre y se purga")
    }

    func testBoxPurgesABinnedFolderWithoutBinningItAgain() async throws {
        serve { method, _, _ in method == "GET" ? (200, Data(#"{"item_status":"trashed"}"#.utf8)) : (204, Data()) }
        try await client(.box).deletePermanently(file: item("9", folder: true))
        XCTAssertEqual(paths, ["GET /2.0/folders/9", "DELETE /2.0/folders/9/trash"])
    }

    // MARK: - Dropbox

    func testDropboxListsDeletedEntriesAmongTheLiveOnesAndRestoresByRevision() async throws {
        serve { _, path, body in
            switch path {
            case "/2/files/list_folder":
                return (200, Data(#"{"entries":[{".tag":"file","name":"vivo.txt","path_lower":"/vivo.txt","size":1},{".tag":"deleted","name":"muerto.txt","path_lower":"/muerto.txt"}],"has_more":false}"#.utf8))
            case "/2/files/list_revisions":
                return (200, Data(#"{"entries":[{"rev":"r1","name":"muerto.txt","path_lower":"/muerto.txt"}]}"#.utf8))
            case "/2/files/permanently_delete":
                return (409, Data(#"{"error_summary":"not_business/..","error":{".tag":"not_business"}}"#.utf8))
            default:
                return (200, Data("{}".utf8))
            }
        }
        let api = client(.dropbox)
        let listed = try await api.list(parent: Collection.trash.rootID)
        XCTAssertTrue(seen[0].body.contains(#""include_deleted":true"#), seen[0].body)
        XCTAssertTrue(seen[0].body.contains(#""recursive":true"#), "Dropbox solo entrega los borrados recorriendo toda la cuenta")
        XCTAssertEqual(listed.map(\.id), ["/muerto.txt"], "Lo vivo no es papelera")

        try await api.restore(file: item("/muerto.txt"))
        XCTAssertEqual(Array(paths[1...]), ["POST /2/files/list_revisions", "POST /2/files/restore"])
        XCTAssertTrue(seen[2].body.contains(#""rev":"r1""#), seen[2].body)

        do {
            try await api.deletePermanently(file: item("/muerto.txt"))
            XCTFail("Una cuenta personal no puede purgar")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Business"), error.localizedDescription) }
    }

    // MARK: - The demo and the volume

    func testTheDemoBinKeepsThingsUntilRestoredOrPurged() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("demo-papelera-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let demo = try DemoStore(directory: directory)
        let folder = try demo.add(name: "Carpeta", parent: "root", folder: true)
        let inside = try demo.add(name: "dentro.txt", parent: folder, content: Data("x".utf8))

        try demo.trash(folder)
        XCTAssertFalse(try demo.list("root").contains { $0.id == folder })
        XCTAssertEqual(try demo.list(Collection.trash.rootID).map(\.id), [folder], "Solo lo enviado, no sus hijos")
        XCTAssertTrue(try demo.searchPage(term: "dentro", cursor: nil, accountID: "demo").hits.isEmpty, "Lo que cuelga de la papelera no aparece en búsquedas")
        XCTAssertThrowsError(try demo.trash(folder), "Dos veces a la papelera no tiene sentido")

        try demo.restore(folder)
        XCTAssertTrue(try demo.list("root").contains { $0.id == folder })
        XCTAssertEqual(try demo.list(folder).map(\.id), [inside], "Vuelve con su contenido")

        try demo.trash(inside)
        try demo.trash(folder)
        try demo.restore(inside)
        XCTAssertTrue(try demo.list("root").contains { $0.id == inside }, "Si la carpeta de origen sigue en la papelera, vuelve a la raíz")

        try demo.emptyTrash()
        XCTAssertTrue(try demo.list(Collection.trash.rootID).isEmpty)
        XCTAssertThrowsError(try demo.restore(folder), "Lo purgado no existe")
        XCTAssertTrue(try demo.list("root").contains { $0.id == inside }, "Vaciar solo toca lo que estaba en la papelera")
        try demo.deletePermanently(inside)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(inside).path), "El contenido purgado desaparece del disco")
    }

    func testAVolumeDeletesForGoodWithoutTouchingTheFinderTrashAndNeverItsOwnRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("volumen-papelera-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("Sub/fuera.txt")
        try Data("adiós".utf8).write(to: target)
        let api = CloudAPI(account: Account(id: "volume:test", cloud: .volume, name: "Prueba", email: "local", clientID: "", clientSecret: nil,
                                            serverURL: root.standardizedFileURL.path))
        try await api.deletePermanently(file: item(target.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        do {
            try await api.deletePermanently(file: item("root", folder: true))
            XCTFail("La carpeta conectada no se elimina desde la app")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: root.path)) }
        do {
            try await api.deletePermanently(file: item("/etc/hosts"))
            XCTFail("Nada fuera de la carpeta conectada")
        } catch { XCTAssertTrue(FileManager.default.fileExists(atPath: "/etc/hosts")) }
    }
}
