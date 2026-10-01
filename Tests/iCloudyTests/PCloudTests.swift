import XCTest
import CryptoKit
@testable import iCloudy

/// pCloud answers HTTP 200 to everything and says what happened in `result`, keeps every account on one of two
/// regional hosts and names items by folderid and fileid. These play its JSON API through the stubbed transport.
@MainActor
final class PCloudTests: XCTestCase {
    /// Every request the stub saw: method, host, path, query (or form body) and the raw body.
    private var seen: [(method: String, host: String, path: String, parameters: [String: String], body: Data)] = []

    override func setUp() { seen = [] }
    override func tearDown() { StubProtocol.handler = nil }

    private func client(host: String? = "eapi.pcloud.com", credentials: CredentialStore? = nil) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "pcloud:7", cloud: .pcloud, name: "Ana", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: host.map { ["apiHost": $0] } ?? [:])
        if let credentials { return CloudAPI(account: account, session: URLSession(configuration: config), credentials: credentials) }
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func temporaryFile(_ payload: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: url)
        return url
    }
    private func json(_ text: String) -> Data { Data(text.utf8) }
    /// Records each request and lets the test answer by method name (the path without its slash).
    private func serve(_ answer: @escaping (_ method: String, _ parameters: [String: String], _ body: Data) -> (Int, Data)) {
        StubProtocol.handler = { [self] request in
            let url = request.url!
            let body = requestData(request)
            var parameters: [String: String] = [:]
            for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] { parameters[item.name] = item.value ?? "" }
            if request.value(forHTTPHeaderField: "Content-Type") == "application/x-www-form-urlencoded" {
                for pair in String(decoding: body, as: UTF8.self).split(separator: "&") {
                    let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
                    parameters[parts[0]] = parts.count > 1 ? parts[1] : ""
                }
            }
            seen.append((request.httpMethod ?? "", url.host ?? "", url.path, parameters, body))
            let (status, data) = answer(String(url.path.dropFirst()), parameters, body)
            return (status, [:], data)
        }
    }
    private var methods: [String] { seen.map { String($0.path.dropFirst()) } }

    // MARK: - Region and identity

    func testEachAccountTalksToItsOwnRegionAndNeverToAnotherHost() async throws {
        serve { _, _, _ in (200, self.json(#"{"result":0,"metadata":{"id":"d0","contents":[]}}"#)) }
        _ = try await client(host: "eapi.pcloud.com").list(parent: "root")
        _ = try await client(host: "api.pcloud.com").list(parent: "root")
        // An account saved before the host was kept, or one whose stored host is not pCloud's, uses the default one.
        _ = try await client(host: nil).list(parent: "root")
        _ = try await client(host: "evil.example.com").list(parent: "root")
        XCTAssertEqual(seen.map(\.host), ["eapi.pcloud.com", "api.pcloud.com", "api.pcloud.com", "api.pcloud.com"])
        XCTAssertEqual(PCloudRegion.host(locationID: 1), "api.pcloud.com")
        XCTAssertEqual(PCloudRegion.host(locationID: 2), "eapi.pcloud.com")
        XCTAssertNil(PCloudRegion.host(locationID: 3))
        XCTAssertEqual(PCloudRegion.host(named: " EAPI.pcloud.com "), "eapi.pcloud.com")
        XCTAssertNil(PCloudRegion.host(named: "eapi.pcloud.com.evil.example"))
    }

    func testTheProviderDeclaresWhatPCloudOffers() {
        let capabilities = Cloud.pcloud.capabilities
        XCTAssertEqual(Cloud.pcloud.title, "pCloud")
        XCTAssertTrue(capabilities.oauth)
        XCTAssertFalse(capabilities.search, "pCloud documenta su API sin método de búsqueda")
        XCTAssertFalse(capabilities.recents)
        XCTAssertFalse(capabilities.sharedWithMe)
        XCTAssertTrue(capabilities.trashListing)
        XCTAssertTrue(capabilities.permanentDelete)
        XCTAssertTrue(capabilities.emptyTrash)
        XCTAssertTrue(capabilities.reversibleTrash)
        XCTAssertTrue(capabilities.checksum)
        XCTAssertTrue(capabilities.copiesFolders)
        XCTAssertFalse(capabilities.memberSharing)
        XCTAssertFalse(Cloud.pcloud.isSelfHosted)
        XCTAssertEqual(Cloud.pcloud.authorizationScheme, "Bearer")
        XCTAssertEqual(Cloud.pcloud.rootAlias, "d0")
    }

    // MARK: - Listing

    func testListingParsesFoldersAndFilesWithStableIDs() async throws {
        serve { method, _, _ in
            XCTAssertEqual(method, "listfolder")
            return (200, self.json(#"""
            {"result":0,"metadata":{"id":"d0","folderid":0,"name":"/","isfolder":true,"contents":[
              {"id":"f44","fileid":44,"name":"nota.txt","isfolder":false,"size":12,"contenttype":"text/plain","modified":1767323045,"hash":123456789},
              {"id":"d9","folderid":9,"name":"Viaje","isfolder":true,"modified":"Thu, 21 Mar 2013 18:31:46 +0000"},
              {"id":"f45","fileid":45,"name":"foto.jpg","isfolder":false,"size":2048,"contenttype":"","modified":1767323045}
            ]}}
            """#))
        }
        let files = try await client().list(parent: "root")
        XCTAssertEqual(seen.first?.parameters["folderid"], "0", "La raíz de iCloudy es la carpeta 0 de pCloud")
        XCTAssertEqual(seen.first?.method, "GET")
        XCTAssertEqual(files.map(\.id), ["d9", "f45", "f44"], "Carpetas primero, después por nombre")
        let folder = files[0], photo = files[1], note = files[2]
        XCTAssertTrue(folder.isFolder)
        XCTAssertNil(folder.size)
        XCTAssertEqual(folder.modified, Date(timeIntervalSince1970: 1_363_890_706), "Fecha RFC 1123 cuando no llega como marca de tiempo")
        XCTAssertEqual(note.size, 12)
        XCTAssertEqual(note.mime, "text/plain")
        XCTAssertEqual(note.modified, Date(timeIntervalSince1970: 1_767_323_045))
        XCTAssertNil(note.checksum, "El `hash` del listado no es una suma del contenido")
        XCTAssertEqual(photo.mime, "image/jpeg", "Sin tipo del servidor se deduce de la extensión")

        // A subfolder is asked for by its folderid, without the "d".
        _ = try await client().list(parent: "d9")
        XCTAssertEqual(seen.last?.parameters["folderid"], "9")
    }

    func testTheBreadcrumbClimbsByParentFolderID() async throws {
        serve { _, parameters, _ in
            switch parameters["folderid"] {
            case "30": return (200, self.json(#"{"result":0,"metadata":{"id":"d30","name":"Hijo","isfolder":true,"parentfolderid":20}}"#))
            case "20": return (200, self.json(#"{"result":0,"metadata":{"id":"d20","name":"Padre","isfolder":true,"parentfolderid":0}}"#))
            default: XCTFail("La raíz no se pide"); return (200, self.json(#"{"result":0}"#))
            }
        }
        let trail = try await client().folderTrail(id: "d30")
        XCTAssertEqual(trail.map(\.name), ["Padre", "Hijo"])
        XCTAssertEqual(trail.map(\.id), ["d20", "d30"])
        XCTAssertTrue(seen.allSatisfy { $0.parameters["nofiles"] == "1" })
    }

    // MARK: - Operations

    func testWritesUseFolderAndFileIDsAndAreNotRepeated() async throws {
        serve { method, _, _ in
            if method == "createfolder" { return (200, self.json(#"{"result":0,"metadata":{"id":"d77","name":"Nueva","isfolder":true}}"#)) }
            return (200, self.json(#"{"result":0}"#))
        }
        let api = client()
        let file = CloudFile(id: "f5", name: "a+b.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        let folder = CloudFile(id: "d6", name: "Carpeta", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        let created = try await api.createFolder(name: "Nueva", parent: "d3")
        XCTAssertEqual(created, "d77")
        try await api.rename(file: file, name: "c+d.txt")
        try await api.rename(file: folder, name: "Otra")
        try await api.move(file: file, to: "root")
        try await api.copy(file: folder, to: "d8")
        try await api.copy(file: file, to: "d8")
        try await api.trash(file: file)
        try await api.trash(file: folder)
        XCTAssertEqual(methods, ["createfolder", "renamefile", "renamefolder", "renamefile", "copyfolder", "copyfile", "deletefile", "deletefolderrecursive"])
        XCTAssertTrue(seen.allSatisfy { $0.method == "POST" }, "Lo que cambia algo va en un formulario, no en la dirección")
        XCTAssertEqual(seen[0].parameters, ["folderid": "3", "name": "Nueva"])
        XCTAssertEqual(seen[1].parameters, ["fileid": "5", "toname": "c+d.txt"], "Un + del nombre no se convierte en espacio")
        XCTAssertEqual(seen[2].parameters, ["folderid": "6", "toname": "Otra"])
        XCTAssertEqual(seen[3].parameters, ["fileid": "5", "tofolderid": "0"], "Mover conserva el nombre")
        XCTAssertEqual(seen[4].parameters, ["folderid": "6", "tofolderid": "8", "noover": "1"], "Copiar nunca sobrescribe")
        XCTAssertEqual(seen[5].parameters, ["fileid": "5", "tofolderid": "8", "noover": "1"])
        XCTAssertEqual(seen[6].parameters, ["fileid": "5"])
        XCTAssertEqual(seen[7].parameters, ["folderid": "6"])
        XCTAssertTrue(seen.allSatisfy { $0.host == "eapi.pcloud.com" })
    }

    func testQuotaComesFromUserInfo() async throws {
        serve { method, _, _ in
            XCTAssertEqual(method, "userinfo")
            return (200, self.json(#"{"result":0,"userid":7,"email":"ana@example.com","quota":10737418240,"usedquota":1073741824}"#))
        }
        let quota = try await client().storageQuota()
        XCTAssertEqual(quota.used, 1_073_741_824)
        XCTAssertEqual(quota.total, 10_737_418_240)
    }

    func testSearchIsDeclinedWithoutARequest() async {
        serve { _, _, _ in XCTFail("No hay método de búsqueda que llamar"); return (500, Data()) }
        do { _ = try await client().searchPage(term: "x"); XCTFail("pCloud no busca") }
        catch { XCTAssertTrue(error.localizedDescription.contains("búsqueda"), error.localizedDescription) }
    }

    func testAPublicLinkIsReusedBeforeAnotherIsMade() async throws {
        var made = 0
        serve { method, _, _ in
            switch method {
            case "listpublinks":
                return (200, self.json(#"{"result":0,"publinks":[{"linkid":31,"code":"XZa","link":"https://u.pcloud.link/publink/show?code=XZa","metadata":{"id":"f5","name":"a.txt"}}]}"#))
            case "getfolderpublink":
                made += 1
                return (200, self.json(#"{"result":0,"linkid":32,"code":"XZb","link":"https://u.pcloud.link/publink/show?code=XZb"}"#))
            case "deletepublink": return (200, self.json(#"{"result":0}"#))
            default: XCTFail(method); return (200, self.json(#"{"result":0}"#))
            }
        }
        let api = client()
        let file = CloudFile(id: "f5", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        let folder = CloudFile(id: "d6", name: "C", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        let existing = try await api.publicLink(for: file)
        XCTAssertEqual(existing.absoluteString, "https://u.pcloud.link/publink/show?code=XZa")
        XCTAssertEqual(made, 0, "El enlace que ya existía se devuelve tal cual")
        let fresh = try await api.publicLink(for: folder)
        XCTAssertEqual(fresh.absoluteString, "https://u.pcloud.link/publink/show?code=XZb")
        XCTAssertEqual(made, 1)
        XCTAssertEqual(seen.last?.parameters, ["folderid": "6"])

        let provider = try XCTUnwrap(api.provider as? PCloudProvider)
        let links = try await provider.pcloudPublicLinks()
        XCTAssertEqual(links, [PCloudPublicLink(id: "31", url: URL(string: "https://u.pcloud.link/publink/show?code=XZa")!, itemID: "f5")])
        try await provider.pcloudDeletePublicLink(links[0])
        XCTAssertEqual(seen.last?.path, "/deletepublink")
        XCTAssertEqual(seen.last?.parameters, ["linkid": "31"])
    }

    // MARK: - Trash

    func testTrashIsListedRestoredClearedAndEmptied() async throws {
        serve { method, parameters, _ in
            switch method {
            case "trash_list":
                XCTAssertEqual(parameters["folderid"], "0")
                return (200, self.json(#"{"result":0,"metadata":{"id":"d0","contents":[{"id":"f5","name":"viejo.txt","isfolder":false,"size":3},{"id":"d6","name":"Vieja","isfolder":true}]}}"#))
            // Binning what is already in the trash answers "not found", which permanent deletion takes in its stride.
            case "deletefile": return (200, self.json(#"{"result":2009,"error":"File not found."}"#))
            default: return (200, self.json(#"{"result":0}"#))
            }
        }
        let api = client()
        let binned = try await api.list(parent: Collection.trash.rootID)
        XCTAssertEqual(binned.map(\.id), ["d6", "f5"])
        try await api.restore(file: binned[1])
        try await api.restore(file: binned[0])
        try await api.deletePermanently(file: binned[1])
        try await api.emptyTrash()
        XCTAssertEqual(methods, ["trash_list", "trash_restore", "trash_restore", "deletefile", "trash_clear", "trash_clear"])
        XCTAssertEqual(seen[1].parameters, ["fileid": "5"])
        XCTAssertEqual(seen[2].parameters, ["folderid": "6"])
        XCTAssertEqual(seen[4].parameters, ["fileid": "5"])
        XCTAssertEqual(seen[5].parameters, ["folderid": "0"], "La carpeta 0 de la papelera es la papelera entera")
    }

    func testDeletingForGoodFromTheTreeBinsFirstAndStopsAtARealRefusal() async throws {
        serve { method, _, _ in
            method == "deletefolderrecursive" ? (200, self.json(#"{"result":2003,"error":"Access denied."}"#)) : (200, self.json(#"{"result":0}"#))
        }
        let api = client()
        let file = CloudFile(id: "f5", name: "a", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.deletePermanently(file: file)
        XCTAssertEqual(methods, ["deletefile", "trash_clear"])
        let folder = CloudFile(id: "d6", name: "C", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)
        do { try await api.deletePermanently(file: folder); XCTFail("Una negativa de verdad no se salta") }
        catch { XCTAssertEqual((error as? ServiceError)?.status, 403) }
        XCTAssertEqual(methods.last, "deletefolderrecursive", "Sin papelera no hay nada que vaciar")
    }

    // MARK: - Errors

    func testResultCodesBecomeSpanishMessagesWithTheRightRetryRule() {
        func service(_ code: Int) -> ServiceError? { PCloudError.error(code: code, detail: "English") as? ServiceError }
        XCTAssertEqual(service(2005)?.status, 404)
        XCTAssertEqual(service(2009)?.status, 404)
        XCTAssertEqual(service(2009)?.detail, L("El archivo ya no existe en pCloud."))
        XCTAssertEqual(service(2004)?.status, 409)
        XCTAssertEqual(service(2008)?.status, 507)
        XCTAssertFalse(service(2008)!.retryable, "Sin espacio no se arregla repitiendo")
        XCTAssertTrue(service(5000)!.retryable, "Un fallo interno se repite")
        XCTAssertTrue(service(5001)!.retryable)
        XCTAssertTrue(service(4000)!.retryable)
        XCTAssertEqual(service(4000)?.retryAfter, 60, "Demasiados intentos: se espera antes de volver")
        XCTAssertEqual(service(2009)?.code, "pcloud.2009")
        for code in [1000, 2000, 2094] {
            let error = PCloudError.error(code: code, detail: "Log in required.")
            XCTAssertTrue((error as? CloudError)?.isSessionExpired == true, "\(code) es una sesión perdida")
        }
        let unknown = service(1234)
        XCTAssertEqual(unknown?.status, 400)
        XCTAssertTrue(unknown?.detail?.contains("1234") == true)
        XCTAssertTrue(unknown?.detail?.contains("English") == true, "Lo desconocido conserva la explicación del proveedor")
        XCTAssertThrowsError(try PCloudError.check(["error": "sin resultado"]))
        XCTAssertNoThrow(try PCloudError.check(["result": 0]))
    }

    func testARefusedTokenMarksTheAccountExpiredOnce() async throws {
        serve { _, _, _ in (200, self.json(#"{"result":2094,"error":"Invalid 'access_token' provided."}"#)) }
        let api = client()
        var reasons: [String?] = []
        api.sessionDidExpire = { reasons.append($0) }
        do { _ = try await api.list(parent: "root"); XCTFail("La sesión ya no vale") }
        catch { XCTAssertTrue((error as? CloudError)?.isSessionExpired == true, "\(error)") }
        XCTAssertTrue(api.sessionExpired)
        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(reasons.first ?? nil, "Invalid 'access_token' provided.")
        XCTAssertEqual(seen.count, 1, "Un token de pCloud no se renueva: no hay segunda petición")
    }

    func testAServerFailureIsRepeatedForReadsButNotForWrites() async throws {
        var listings = 0
        serve { method, _, _ in
            if method == "listfolder" {
                listings += 1
                return listings == 1 ? (200, self.json(#"{"result":5000,"error":"Internal error."}"#)) : (200, self.json(#"{"result":0,"metadata":{"contents":[]}}"#))
            }
            return (200, self.json(#"{"result":5000,"error":"Internal error."}"#))
        }
        let api = client()
        _ = try await api.list(parent: "root")
        XCTAssertEqual(listings, 2, "Leer otra vez no cambia nada")
        do { _ = try await api.createFolder(name: "x", parent: "root"); XCTFail("Debe fallar") }
        catch { XCTAssertEqual((error as? ServiceError)?.status, 503, "Y la cola lo reintentará") }
        XCTAssertEqual(methods.filter { $0 == "createfolder" }.count, 1, "Una carpeta no se crea dos veces por un reintento")
    }

    // MARK: - Uploads

    func testASmallFileGoesUpInOnePutAndIsVerified() async throws {
        let payload = Data("hola pCloud".utf8)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let sha256 = UploadHasher.hex(SHA256.hash(data: payload))
        serve { method, _, body in
            XCTAssertEqual(method, "uploadfile")
            XCTAssertEqual(body, payload)
            return (200, self.json(#"{"result":0,"metadata":[{"id":"f90","name":"a+b ñ.txt","size":11}],"checksums":[{"sha1":"x","sha256":"\#(sha256)"}],"fileids":[90]}"#))
        }
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let receipt = try await client().resumableUpload(local: file, parent: "d3", name: "a+b ñ.txt", replacing: nil,
                                                         checkpoint: UploadCheckpoint(total: Int64(payload.count), modified: stamp), save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "f90")
        XCTAssertEqual(receipt.verification, .verified)
        let request = try XCTUnwrap(seen.first)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.parameters["filename"], "a+b ñ.txt", "El nombre va como parámetro, sin cabeceras multiparte")
        XCTAssertEqual(request.parameters["folderid"], "3")
        XCTAssertEqual(request.parameters["nopartial"], "1")
        XCTAssertEqual(request.parameters["renameifexists"], "1", "Un archivo nuevo nunca pisa a otro del mismo nombre")
        XCTAssertNil(request.parameters["name"])
    }

    func testReplacingOverwritesAndAWrongChecksumFailsTheUpload() async throws {
        let payload = Data("contenido".utf8)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        serve { _, _, _ in (200, self.json(#"{"result":0,"metadata":[{"id":"f90"}],"checksums":[{"sha1":"0000000000000000000000000000000000000000"}]}"#)) }
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var saved: [UploadCheckpoint] = []
        do {
            _ = try await client(host: "api.pcloud.com").resumableUpload(local: file, parent: "d3", name: "a.txt", replacing: "f90",
                                                                         checkpoint: UploadCheckpoint(total: Int64(payload.count), modified: stamp),
                                                                         save: { saved.append($0) }, progress: { _, _ in })
            XCTFail("Una suma distinta no puede darse por buena")
        } catch { XCTAssertTrue(error.localizedDescription.contains("suma de verificación"), error.localizedDescription) }
        XCTAssertNil(seen.first?.parameters["renameifexists"], "Reemplazar es justo sobrescribir")
        XCTAssertEqual(saved.last?.integrity, .failed)
        XCTAssertTrue(saved.last?.complete == true, "La subida existe en el servidor: no se repite sin más")
    }

    func testAChunkedUploadIsSavedVerifiedAndResumedFromWhatTheServerHas() async throws {
        let chunk = Int(PCloudProvider.pcloudChunk)
        let size = Int(PCloudProvider.pcloudSessionThreshold) + 1000
        var payload = Data(count: size)
        for index in stride(from: 0, to: size, by: 4099) { payload[index] = UInt8(index % 251) }
        let sha256 = UploadHasher.hex(SHA256.hash(data: payload))
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        var received = Data(), serverSize = 0
        serve { method, parameters, body in
            switch method {
            case "upload_create": return (200, self.json(#"{"result":0,"uploadid":77}"#))
            case "upload_info": return (200, self.json(#"{"result":0,"size":\#(serverSize)}"#))
            case "upload_write":
                XCTAssertEqual(parameters["uploadid"], "77")
                XCTAssertEqual(Int(parameters["uploadoffset"] ?? ""), received.count, "Cada bloque empieza donde acabó el anterior")
                received.append(body)
                return (200, self.json(#"{"result":0}"#))
            case "upload_save":
                XCTAssertEqual(parameters["uploadid"], "77")
                XCTAssertEqual(parameters["name"], "grande.bin")
                XCTAssertEqual(parameters["folderid"], "3")
                return (200, self.json(#"{"result":0,"metadata":{"id":"f91","name":"grande.bin"}}"#))
            case "checksumfile":
                XCTAssertEqual(parameters["fileid"], "91")
                return (200, self.json(#"{"result":0,"sha1":"x","sha256":"\#(sha256)","metadata":{"id":"f91"}}"#))
            default: XCTFail(method); return (200, self.json(#"{"result":0}"#))
            }
        }
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var checkpoints: [UploadCheckpoint] = []
        let fresh = try await client().resumableUpload(local: file, parent: "d3", name: "grande.bin", replacing: nil,
                                                       checkpoint: UploadCheckpoint(total: Int64(size), modified: stamp),
                                                       save: { checkpoints.append($0) }, progress: { _, _ in })
        XCTAssertEqual(methods, ["upload_create", "upload_write", "upload_write", "upload_write", "upload_save", "checksumfile"])
        XCTAssertEqual(received, payload)
        XCTAssertTrue(seen.filter { $0.path == "/upload_write" }.allSatisfy { $0.method == "PUT" })
        XCTAssertEqual(fresh.remoteID, "f91")
        XCTAssertEqual(fresh.verification, .verified)
        XCTAssertTrue(checkpoints.contains { $0.sessionID == "77" && $0.offset == Int64(chunk) }, "El punto de control guarda la sesión y el avance")

        // Interrupted after the first block. The server holds two blocks, because the checkpoint of the second
        // never reached the disk: it is the server that says where to carry on.
        seen = []; received = payload.prefix(2 * chunk); serverSize = 2 * chunk
        var resumed = UploadCheckpoint(total: Int64(size), modified: stamp)
        resumed.sessionID = "77"; resumed.chunkSize = Int64(chunk); resumed.offset = Int64(chunk)
        let receipt = try await client().resumableUpload(local: file, parent: "d3", name: "grande.bin", replacing: nil,
                                                         checkpoint: resumed, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(methods, ["upload_info", "upload_write", "upload_save", "checksumfile"], "Solo viaja lo que falta")
        XCTAssertEqual(received, payload)
        XCTAssertEqual(receipt.verification, .verified, "El resumen cubre el archivo entero, reanudado o no")
    }

    func testAnUploadSessionPCloudForgotStartsAgain() async throws {
        let size = Int(PCloudProvider.pcloudSessionThreshold) + 10
        let payload = Data(repeating: 3, count: size)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        var received = Data()
        serve { method, _, body in
            switch method {
            case "upload_info": return (200, self.json(#"{"result":1900,"error":"Upload not found."}"#))
            case "upload_create": return (200, self.json(#"{"result":0,"uploadid":78}"#))
            case "upload_write": received.append(body); return (200, self.json(#"{"result":0}"#))
            case "upload_save": return (200, self.json(#"{"result":0,"metadata":{"id":"f92"}}"#))
            // Without a digest to compare, the upload stands but is not called verified.
            default: return (200, self.json(#"{"result":0,"metadata":{"id":"f92"}}"#))
            }
        }
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var checkpoint = UploadCheckpoint(total: Int64(size), modified: stamp)
        checkpoint.sessionID = "70"; checkpoint.offset = PCloudProvider.pcloudChunk
        let receipt = try await client().resumableUpload(local: file, parent: "root", name: "x.bin", replacing: nil,
                                                         checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(Array(methods.prefix(2)), ["upload_info", "upload_create"])
        XCTAssertEqual(received, payload, "Se vuelve a enviar desde el primer byte")
        XCTAssertEqual(receipt.remoteID, "f92")
        XCTAssertEqual(receipt.verification, .unavailable)
    }

    func testCancellingAnUploadDeletesItsSession() async {
        serve { _, _, _ in (200, self.json(#"{"result":0}"#)) }
        await client().abandonUploadSessions(urls: [], boxSessions: ["77"])
        XCTAssertEqual(methods, ["upload_delete"])
        XCTAssertEqual(seen.first?.parameters, ["uploadid": "77"])
    }

    // MARK: - Downloads

    func testADownloadFollowsTheFileLinkWithoutTheToken() async throws {
        let payload = Data("contenido remoto".utf8)
        var contentAuthorization: String?
        StubProtocol.handler = { request in
            if request.url?.host == "c123.pcloud.com" {
                contentAuthorization = request.value(forHTTPHeaderField: "Authorization")
                XCTAssertEqual(request.url?.path, "/cBZ/archivo con espacio.txt")
                return (200, [:], payload)
            }
            XCTAssertEqual(request.url?.path, "/getfilelink")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            return (200, [:], Data(#"{"result":0,"path":"/cBZ/archivo%20con%20espacio.txt","hosts":["c123.pcloud.com","p4-c123.pcloud.com"]}"#.utf8))
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let file = CloudFile(id: "f5", name: "archivo con espacio.txt", mime: "text/plain", size: Int64(payload.count), modified: nil, webURL: nil, isFolder: false)
        _ = try await client().download(file: file, to: target, checksum: false)
        XCTAssertEqual(try Data(contentsOf: target), payload)
        XCTAssertNil(contentAuthorization, "El enlace firmado es la credencial: el token no viaja al servidor de contenido")
    }

    func testDownloadsAreCheckedAgainstTheDigestPCloudReports() async throws {
        let payload = Data("contenido remoto".utf8)
        let modified = 1_767_323_045
        var reported = UploadHasher.hex(SHA256.hash(data: payload)), asked = 0
        StubProtocol.handler = { request in
            switch request.url?.path {
            case "/checksumfile":
                asked += 1
                XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "fileid" }?.value, "5")
                return (200, [:], Data(#"{"result":0,"sha1":"x","sha256":"\#(reported)","metadata":{"id":"f5","name":"a.txt","size":\#(payload.count),"modified":\#(modified)}}"#.utf8))
            case "/getfilelink":
                return (200, [:], Data(#"{"result":0,"path":"/cBZ/a.txt","hosts":["c1.pcloud.com"]}"#.utf8))
            default:
                return (200, [:], payload)
            }
        }
        let file = CloudFile(id: "f5", name: "a.txt", mime: "text/plain", size: Int64(payload.count),
                             modified: Date(timeIntervalSince1970: 1_767_323_045), webURL: nil, isFolder: false)
        let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: target) }
        let api = client()
        let verified = try await api.download(file: file, to: target)
        XCTAssertEqual(verified, .verified, "El listado no trae suma, pero checksumfile sí")
        XCTAssertEqual(asked, 1)
        try FileManager.default.removeItem(at: target)

        // The same digest twice, and not the one of the bytes that arrived: the copy is damaged.
        reported = String(repeating: "0", count: 64); asked = 0
        do { _ = try await api.download(file: file, to: target); XCTFail("Una suma distinta no se da por buena") }
        catch { XCTAssertEqual(error as? DownloadIntegrityError, .checksumMismatch(name: "a.txt")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "La copia dañada no se queda en el destino")
        XCTAssertEqual(asked, 2, "Antes de culpar a la descarga se vuelve a preguntar por el archivo")

        // The file changed between the question and the download: that is a remote change, worth retrying.
        asked = 0
        StubProtocol.handler = { [payload] request in
            switch request.url?.path {
            case "/checksumfile":
                asked += 1
                let digest = asked == 1 ? String(repeating: "0", count: 64) : "1" + String(repeating: "0", count: 63)
                return (200, [:], Data(#"{"result":0,"sha256":"\#(digest)","metadata":{"id":"f5","name":"a.txt","size":\#(payload.count),"modified":\#(1_767_323_045 + asked)}}"#.utf8))
            case "/getfilelink": return (200, [:], Data(#"{"result":0,"path":"/a","hosts":["c1.pcloud.com"]}"#.utf8))
            default: return (200, [:], payload)
            }
        }
        do { _ = try await api.download(file: file, to: target); XCTFail("Debe fallar") }
        catch { XCTAssertTrue((error as? DownloadIntegrityError)?.retryable == true, "\(error)") }

        // Without the check (a preview above its limit) nothing extra is asked.
        asked = 0
        _ = try await api.download(file: file, to: target, checksum: false)
        XCTAssertEqual(asked, 0)
    }

    // MARK: - Sign-in

    private func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    func testTheCodeIsTradedOnTheRegionTheCallbackNames() async throws {
        serve { method, parameters, _ in
            if method == "oauth2_token" {
                XCTAssertEqual(parameters, ["client_id": "clienteid1", "client_secret": "secreto", "code": "el-código"])
                return (200, self.json(#"{"result":0,"access_token":"tok","token_type":"bearer","uid":7,"locationid":2}"#))
            }
            XCTAssertEqual(method, "userinfo")
            return (200, self.json(#"{"result":0,"userid":7,"email":"ana@example.com","quota":10,"usedquota":1}"#))
        }
        let callback = [URLQueryItem(name: "code", value: "el-código"), URLQueryItem(name: "locationid", value: "2"),
                        URLQueryItem(name: "hostname", value: "eapi.pcloud.com")]
        let (account, credential) = try await PCloudAuthentication.complete(code: "el-código", callback: callback, clientID: "clienteid1",
                                                                            clientSecret: "secreto", session: stubbedSession())
        XCTAssertEqual(seen.map(\.host), ["eapi.pcloud.com", "eapi.pcloud.com"], "Ni el código ni el token pasan por Estados Unidos")
        XCTAssertEqual(seen.first?.method, "POST", "El secreto va en el cuerpo, no en la dirección")
        XCTAssertEqual(account.id, "pcloud:7")
        XCTAssertEqual(account.cloud, .pcloud)
        XCTAssertEqual(account.email, "ana@example.com")
        XCTAssertEqual(account.options["apiHost"], "eapi.pcloud.com")
        XCTAssertEqual(account.options["locationid"], "2")
        XCTAssertNil(account.clientSecret, "Sin refresh token no hay nada para lo que guardar el secreto")
        XCTAssertEqual(credential.accessToken, "tok")
        XCTAssertFalse(credential.isRenewable)
        XCTAssertEqual(credential.expires, .distantFuture, "Los tokens de pCloud no caducan")
        XCTAssertEqual(PCloudRegion.host(for: account), "eapi.pcloud.com")
    }

    func testWithoutARegionTheCodeIsTriedInEuropeAfterTheUnitedStates() async throws {
        serve { method, _, _ in
            guard method == "oauth2_token" else { return (200, self.json(#"{"result":0,"userid":8,"email":"eu@example.com"}"#)) }
            return self.seen.last?.host == "api.pcloud.com"
                ? (200, self.json(#"{"result":2012,"error":"Invalid 'code' provided."}"#))
                : (200, self.json(#"{"result":0,"access_token":"tok","hostname":"eapi.pcloud.com"}"#))
        }
        let (account, _) = try await PCloudAuthentication.complete(code: "c", callback: [URLQueryItem(name: "code", value: "c")],
                                                                   clientID: "clienteid1", clientSecret: "secreto", session: stubbedSession())
        XCTAssertEqual(seen.map { "\($0.host)\($0.path)" },
                       ["api.pcloud.com/oauth2_token", "eapi.pcloud.com/oauth2_token", "eapi.pcloud.com/userinfo"])
        XCTAssertEqual(account.options["apiHost"], "eapi.pcloud.com")
    }

    func testTheTokenAnswerDecidesTheRegionAndAnUnknownHostIsNeverTrusted() async throws {
        serve { method, _, _ in
            method == "oauth2_token" ? (200, self.json(#"{"result":0,"access_token":"tok","locationid":2,"hostname":"evil.example.com"}"#))
                                     : (200, self.json(#"{"result":0,"userid":9,"email":"x@example.com"}"#))
        }
        let (account, _) = try await PCloudAuthentication.complete(code: "c", callback: [], clientID: "clienteid1", clientSecret: "secreto",
                                                                   session: stubbedSession())
        XCTAssertEqual(seen.map(\.host), ["api.pcloud.com", "eapi.pcloud.com"], "Un nombre desconocido se ignora; vale el número de región")
        XCTAssertEqual(account.options["apiHost"], "eapi.pcloud.com")

        // A callback that names another host is refused before the secret leaves the Mac.
        seen = []
        do {
            _ = try await PCloudAuthentication.complete(code: "c", callback: [URLQueryItem(name: "hostname", value: "evil.example.com")],
                                                        clientID: "clienteid1", clientSecret: "secreto", session: stubbedSession())
            XCTFail("Un servidor ajeno no recibe el código")
        } catch { XCTAssertTrue(error.localizedDescription.contains("servidor desconocido"), error.localizedDescription) }
        XCTAssertTrue(seen.isEmpty)
    }

    func testARefusedCodeIsExplainedInsteadOfLookingLikeASuccess() async {
        serve { _, _, _ in (200, self.json(#"{"result":2012,"error":"Invalid 'code' provided."}"#)) }
        do {
            _ = try await PCloudAuthentication.complete(code: "c", callback: [URLQueryItem(name: "hostname", value: "api.pcloud.com")],
                                                        clientID: "clienteid1", clientSecret: "secreto", session: stubbedSession())
            XCTFail("pCloud rechazó el código")
        } catch { XCTAssertEqual(error.localizedDescription, L("pCloud no aceptó el código de autorización. Vuelve a intentar la conexión.")) }
        XCTAssertEqual(seen.count, 1, "Con la región conocida no se prueba otra")
    }

    func testOnlyPCloudMayComeBackWithoutTheState() throws {
        XCTAssertEqual(try OAuthRequest.callbackCode(target: "/callback?code=a&locationid=2&hostname=eapi.pcloud.com", expectedState: "s",
                                                     toleratesMissingState: true), "a")
        XCTAssertThrowsError(try OAuthRequest.callbackCode(target: "/callback?code=a", expectedState: "s"), "Los demás siguen exigiéndolo")
        for target in ["/callback?code=a&state=otro", "/callback?code=a&state=s&state=s", "/callback?code=&state=s"] {
            XCTAssertThrowsError(try OAuthRequest.callbackCode(target: target, expectedState: "s", toleratesMissingState: true), target)
        }
        XCTAssertEqual(OAuthProviderSettings.settings(for: .pcloud)?.toleratesMissingState, true)
        for cloud in [Cloud.google, .microsoft, .dropbox, .box] {
            XCTAssertEqual(OAuthProviderSettings.settings(for: cloud)?.toleratesMissingState, false, "\(cloud)")
        }
        XCTAssertFalse(OAuthRequest.toleratesAnyPort(.pcloud), "La dirección registrada se compara entera")
        let url = OAuthRequest.authorizationURL(cloud: .pcloud, clientID: "clienteid1", state: "s", challenge: "c")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(url.host, "my.pcloud.com")
        XCTAssertEqual(url.path, "/oauth2/authorize")
        XCTAssertEqual(query.first { $0.name == "response_type" }?.value, "code")
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, OAuthRequest.redirectURI)
        XCTAssertNil(query.first { $0.name == "client_secret" })
    }

    func testAPermanentTokenIsUsedAsIsAndNeverRenewed() async throws {
        StubProtocol.handler = { request in XCTFail("Nada que renovar: \(request.url!)"); return (500, [:], Data()) }
        let store = MemoryCredentials()
        store.stored["pcloud:7"] = .permanent(accessToken: "para-siempre")
        let api = client(credentials: store)
        let token = try await api.token()
        XCTAssertEqual(token, "para-siempre")
        do { _ = try await api.token(force: true); XCTFail("Si pCloud lo rechaza, solo queda volver a conectar") }
        catch { XCTAssertTrue((error as? CloudError)?.isSessionExpired == true, "\(error)") }
        XCTAssertTrue(api.sessionExpired)

        // An entry saved without its expiry reads as already expired; without a refresh token it is still used as is.
        let legacy = try JSONDecoder().decode(Credential.self, from: Data(#"{"accessToken":"viejo","refreshToken":""}"#.utf8))
        XCTAssertEqual(legacy.expires, .distantPast)
        store.stored["pcloud:7"] = legacy
        let reread = try await client(credentials: store).token()
        XCTAssertEqual(reread, "viejo")
    }

    func testTheConfigurationNeedsBothTheClientIDAndTheSecret() throws {
        let config = OAuthConfiguration(pcloudClientID: "abcdEFGH123", pcloudClientSecret: "secreto")
        let client = try config.client(for: .pcloud)
        XCTAssertEqual(client.id, "abcdEFGH123")
        XCTAssertEqual(client.secret, "secreto")
        XCTAssertThrowsError(try OAuthConfiguration(pcloudClientID: "abcdEFGH123").client(for: .pcloud), "Sin PKCE el secreto es imprescindible")
        XCTAssertThrowsError(try OAuthConfiguration(pcloudClientID: "corto", pcloudClientSecret: "s").client(for: .pcloud))
        XCTAssertThrowsError(try OAuthConfiguration(pcloudClientID: "con espacios", pcloudClientSecret: "s").client(for: .pcloud))
        let legacy = Data(#"<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>boxClientID</key><string>x</string></dict></plist>"#.utf8)
        XCTAssertEqual(try PropertyListDecoder().decode(OAuthConfiguration.self, from: legacy).pcloudClientID, "", "Un plist anterior sigue leyéndose")
        let example = try PropertyListDecoder().decode(OAuthConfiguration.self, from: Data(contentsOf: URL(fileURLWithPath: "Configuration/OAuth.example.plist")))
        XCTAssertEqual(example.pcloudClientSecret, "")
        let plist = try String(contentsOf: URL(fileURLWithPath: "Configuration/OAuth.example.plist"), encoding: .utf8)
        XCTAssertTrue(plist.contains("<key>pcloudClientID</key>") && plist.contains("<key>pcloudClientSecret</key>"))
    }
}

