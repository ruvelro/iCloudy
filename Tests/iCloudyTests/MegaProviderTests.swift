import XCTest
@testable import iCloudy

/// Mega's own servers cannot be used in a test, so these run against a stand-in that speaks the same protocol and is
/// built with the published algorithm rather than with iCloudy's code paths. That covers everything except Mega
/// changing its API, which is exactly the risk the provider is marked experimental for.
@MainActor
final class MegaProviderTests: XCTestCase {
    private let masterKey = Data((1...16).map(UInt8.init))
    private let session = "sesión-de-prueba"
    /// Contents long enough to cross the first chunk boundary, so the chunking and the MAC are exercised.
    private lazy var contents = Data((0..<200_000).map { UInt8($0 % 251) })
    private var fileKey = Data()
    private var lastUpload: (offset: Int64, body: Data)?
    /// How many times the stand-in storage server should answer "wait" before accepting a piece.
    private var uploadRefusals = 0
    private var registered: [String: Any]?

    override func setUpWithError() throws {
        let key = Data((17...32).map(UInt8.init))
        let nonce = Data((1...8).map(UInt8.init))
        let macs = try MegaCrypto.chunks(of: Int64(contents.count)).map { chunk in
            try MegaCrypto.chunkMAC(contents[Int(chunk.offset)..<Int(chunk.offset + chunk.length)], key: key, nonce: nonce)
        }
        fileKey = MegaCrypto.pack(key: key, nonce: nonce, mac: try MegaCrypto.metaMAC(chunks: macs, key: key))
        lastUpload = nil; registered = nil
    }
    override func tearDown() { StubProtocol.handler = nil }

    // MARK: - The stand-in server

    /// Attributes beside the name that a node may carry, the way MEGAsync writes its fingerprint.
    private var extraAttributes: [String: [String: Any]] = [:]
    /// The key of a folder another account shared in, and the key that folder's contents are wrapped with.
    private let shareKey = Data((40...55).map(UInt8.init))
    private let sharedFolderKey = Data((60...75).map(UInt8.init))
    private func entry(_ handle: String, parent: String, kind: Int, name: String, key: Data,
                       size: Int? = nil, master: Data? = nil, owner: String = "PROPIA") throws -> [String: Any] {
        let content = kind == 0 ? (MegaCrypto.unpack(fileKey: key)?.key ?? Data()) : key
        var attributes: [String: Any] = extraAttributes[handle] ?? [:]
        attributes["n"] = name
        var node: [String: Any] = ["h": handle, "p": parent, "t": kind, "ts": 1_700_000_000,
                                   "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(attributes, key: content)),
                                   "k": owner + ":" + MegaCrypto.encode(try MegaCrypto.ecb(key, key: master ?? masterKey, encrypt: true))]
        if let size { node["s"] = size }
        return node
    }
    /// The `ok` array of an `f` response: the share keys, each wrapped with the account's master key.
    private func shares() throws -> [[String: Any]] {
        [["h": "ORIGEN", "k": MegaCrypto.encode(try MegaCrypto.ecb(shareKey, key: masterKey, encrypt: true))]]
    }
    private func tree() throws -> [[String: Any]] {
        [["h": "RAIZ", "p": "", "t": 2, "ts": 1_700_000_000],
         ["h": "PAPELERA", "p": "", "t": 4, "ts": 1_700_000_000],
         try entry("CARPETA", parent: "RAIZ", kind: 1, name: "Documentos", key: Data((1...16).map { UInt8($0 * 3) })),
         try entry("ARCHIVO", parent: "RAIZ", kind: 0, name: "informe.pdf", key: fileKey, size: contents.count),
         // Shared into the account with a key this account cannot unwrap.
         try entry("AJENO", parent: "RAIZ", kind: 0, name: "de otro.txt", key: try MegaCrypto.randomKey(),
                   size: 10, master: Data(repeating: 9, count: 16)),
         // Shared into the account: wrapped with the key of the share it arrived in, not with the master key.
         try entry("COMPARTIDO", parent: "RAIZ", kind: 1, name: "De Ana", key: sharedFolderKey,
                   master: shareKey, owner: "ORIGEN"),
         try entry("BORRADO", parent: "PAPELERA", kind: 0, name: "informe viejo.pdf", key: fileKey, size: 3)]
    }
    /// One handler for the whole protocol: the command endpoint, the download host and the upload host.
    private func serve(extra: @escaping (String, [String: Any]) throws -> (Int, Data)? = { _, _ in nil }) {
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            if url.host == "g.api.mega.co.nz" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(url.path, "/cs")
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertNotNil(query.first { $0.name == "id" }?.value, "Cada petición lleva su número de secuencia")
                let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
                let action = command["a"] as? String ?? ""
                if let answer = try extra(action, command) { return (answer.0, [:], answer.1) }
                switch action {
                case "f":
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["f": try tree(), "ok": try shares(), "sn": "xyz"]]))
                case "g":
                    XCTAssertEqual(command["ssl"] as? Int, 2, "Se pide la dirección de transferencia cifrada")
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["g": "http://descarga.ejemplo.com/token", "s": contents.count]]))
                case "u":
                    XCTAssertEqual(command["ssl"] as? Int, 2)
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["p": "http://subida.ejemplo.com/destino"]]))
                case "p":
                    registered = (command["n"] as? [[String: Any]])?.first
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["f": [["h": "NUEVO", "t": 0]]]]))
                case "l":
                    return (200, [:], Data(#"["ENLACE123"]"#.utf8))
                case "uq":
                    return (200, [:], Data(#"[{"cstrg":1024,"mstrg":4096}]"#.utf8))
                default:
                    return (200, [:], Data("[0]".utf8))
                }
            }
            if url.host == "descarga.ejemplo.com" {
                XCTAssertEqual(url.scheme, "https", "Una dirección en claro se eleva antes de usarse")
                // The path carries the byte range, the way Mega's temporary links work.
                let range = url.lastPathComponent.split(separator: "-").compactMap { Int($0) }
                let bounds = try XCTUnwrap(range.count == 2 ? range : nil)
                let parts = try XCTUnwrap(MegaCrypto.unpack(fileKey: fileKey))
                let slice = contents[bounds[0]...bounds[1]]
                let cipher = try MegaCrypto.ctr(Data(slice), key: parts.key, nonce: parts.nonce, blockOffset: UInt64(bounds[0] / 16))
                return (200, [:], cipher)
            }
            if url.host == "subida.ejemplo.com" {
                XCTAssertEqual(url.scheme, "https")
                if uploadRefusals > 0 { uploadRefusals -= 1; return (200, [:], Data("-3".utf8)) }
                let offset = Int64(url.lastPathComponent) ?? -1
                let body = requestData(request)
                lastUpload = (offset, (lastUpload?.body ?? Data()) + body)
                return (200, [:], Data("RECIBO".utf8))
            }
            XCTFail("Petición inesperada a \(url)")
            return (500, [:], Data())
        }
    }
    private func client() -> CloudAPI {
        let store = MemoryCredentials()
        store.stored["mega:ana@ejemplo.com"] = Credential(accessToken: session, refreshToken: "", expires: .distantFuture,
                                                          secret: MegaCrypto.encode(masterKey))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let account = Account(id: "mega:ana@ejemplo.com", cloud: .mega, name: "Mega", email: "ana@ejemplo.com",
                              clientID: "", clientSecret: nil)
        return CloudAPI(account: account, session: URLSession(configuration: configuration), credentials: store)
    }

    // MARK: - Signing in

    func testSignInUnwrapsTheChallengeWithTheAccountPrivateKey() async throws {
        // A small but genuine RSA key, so the challenge can only be answered with the private half.
        let p = Self.primeP, q = Self.primeQ
        let privateExponent = Self.privateExponent
        let arithmetic = try XCTUnwrap(MegaMontgomery(modulus: p * q))
        let plain = Data([0x7F] + (0..<47).map { UInt8($0 + 3) })
        let challenge = arithmetic.power(base: MegaBigInt(plain), exponent: Self.publicExponent)
        XCTAssertEqual(arithmetic.power(base: challenge, exponent: privateExponent).data, plain, "La pareja de exponentes es válida")

        let password = "una contraseña larga"
        let salt = Data((1...16).map { UInt8($0 * 7) })
        let derived = try MegaCrypto.derive(password: password, salt: salt)
        var privateKey = Self.integer(p) + Self.integer(q) + Self.integer(privateExponent) + Self.integer(MegaBigInt(1))
        privateKey.append(Data(count: (16 - privateKey.count % 16) % 16))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        var seen: [String] = []
        StubProtocol.handler = { [self] request in
            let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
            seen.append(command["a"] as? String ?? "")
            switch command["a"] as? String {
            case "us0":
                XCTAssertEqual(command["user"] as? String, "ana@ejemplo.com", "El correo se normaliza a minúsculas")
                return (200, [:], try JSONSerialization.data(withJSONObject: [["s": MegaCrypto.encode(salt), "v": 2]]))
            case "us":
                XCTAssertEqual(command["uh"] as? String, derived.hash, "Se envía la prueba derivada, nunca la contraseña")
                XCTAssertNil(command["mfa"], "Sin código de dos pasos no se manda el campo")
                return (200, [:], try JSONSerialization.data(withJSONObject: [[
                    "k": MegaCrypto.encode(try MegaCrypto.ecb(masterKey, key: derived.key, encrypt: true)),
                    "privk": MegaCrypto.encode(try MegaCrypto.ecb(privateKey, key: masterKey, encrypt: true)),
                    "csid": MegaCrypto.encode(Self.integer(challenge))]]))
            default:
                XCTFail("Petición inesperada"); return (500, [:], Data())
            }
        }
        defer { StubProtocol.handler = nil }
        let signed = try await MegaAPI.signIn(email: "  Ana@Ejemplo.com ", password: password, code: nil,
                                              session: URLSession(configuration: configuration))
        XCTAssertEqual(seen, ["us0", "us"])
        XCTAssertEqual(signed.masterKey, masterKey, "La clave maestra se recupera con la contraseña")
        XCTAssertEqual(signed.sid, MegaCrypto.encode(plain.prefix(43)), "La sesión son los primeros 43 bytes del desafío")
    }

    func testAWrongPasswordIsReportedAsSuchAndTwoStepCodesAreSentAlong() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        var sentCode: String?
        StubProtocol.handler = { request in
            let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
            switch command["a"] as? String {
            case "us0": return (200, [:], try JSONSerialization.data(withJSONObject: [["s": MegaCrypto.encode(Data(count: 16)), "v": 2]]))
            default:
                sentCode = command["mfa"] as? String
                // Eight bytes instead of sixteen: what a key unwrapped with the wrong password looks like.
                return (200, [:], try JSONSerialization.data(withJSONObject: [["k": MegaCrypto.encode(Data(count: 8))]]))
            }
        }
        defer { StubProtocol.handler = nil }
        do {
            _ = try await MegaAPI.signIn(email: "ana@ejemplo.com", password: "mala", code: "123456",
                                         session: URLSession(configuration: configuration))
            XCTFail("Debe rechazar la contraseña")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("contraseña de Mega no es correcta"), error.localizedDescription)
        }
        XCTAssertEqual(sentCode, "123456", "El código de dos pasos viaja en la misma petición")
    }

    // MARK: - Browsing

    func testTheTreeIsDecryptedAndTheBinIsKeptOutOfTheWay() async throws {
        serve()
        let api = client()
        let files = try await api.list(parent: "root")
        XCTAssertEqual(files.map(\.name), ["De Ana", "Documentos", "Elemento sin acceso", "informe.pdf"],
                       "Carpetas primero y luego por nombre")
        let file = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        XCTAssertEqual(file.name, "informe.pdf")
        XCTAssertEqual(file.size, Int64(contents.count))
        XCTAssertEqual(file.mime, "application/pdf")
        XCTAssertFalse(file.isFolder)
        XCTAssertEqual(file.modified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(try XCTUnwrap(files.first { $0.id == "CARPETA" }).isFolder)

        // A node shared with a key belonging to another account is shown as unavailable, not with a wrong name.
        let foreign = try XCTUnwrap(files.first { $0.id == "AJENO" })
        XCTAssertEqual(foreign.name, "Elemento sin acceso")
    }

    func testSearchAndBreadcrumbsNeedNoExtraRequest() async throws {
        var commands: [String] = []
        serve { action, _ in commands.append(action); return nil }
        let api = client()
        _ = try await api.list(parent: "root")
        commands.removeAll()

        let page = try await api.searchPage(term: "INFORME")
        XCTAssertEqual(page.hits.map(\.file.name), ["informe.pdf"], "La papelera no aparece en los resultados")
        XCTAssertEqual(page.hits.first?.parentID, "RAIZ")
        XCTAssertNil(page.next)

        let trail = try await api.folderTrail(id: "CARPETA")
        XCTAssertEqual(trail.map(\.name), ["Documentos"], "La raíz no se muestra como una carpeta más")
        XCTAssertTrue(commands.isEmpty, "Ni la búsqueda ni las migas piden nada al servidor")
    }

    func testQuotaAndPublicLinksComeFromTheAccountItself() async throws {
        serve()
        let api = client()
        let quota = try await api.storageQuota()
        XCTAssertEqual(quota.used, 1024)
        XCTAssertEqual(quota.total, 4096)

        let files = try await api.list(parent: "root")
        let shared = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        let link = try await api.publicLink(for: shared)
        XCTAssertEqual(link.scheme, "https")
        XCTAssertEqual(link.path, "/file/ENLACE123")
        // The key travels in the fragment, which a browser never sends to the server.
        XCTAssertEqual(link.fragment, MegaCrypto.encode(fileKey))

        // A folder is a different flow: Mega makes a share with its own key and re-encrypts every child key under
        // it. Publishing the folder's own key, as this used to, produced a link that opens nothing.
        let folder = try XCTUnwrap(files.first { $0.id == "CARPETA" })
        do { _ = try await api.publicLink(for: folder); XCTFail("Un enlace que no abre es peor que no darlo") }
        catch { XCTAssertTrue(error.localizedDescription.contains("desde mega.nz"), error.localizedDescription) }
    }

    // MARK: - Contents

    func testADownloadIsDecryptedAndCheckedAgainstItsOwnKey() async throws {
        serve()
        let api = client()
        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first { $0.id == "ARCHIVO" })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var progress: [Int64] = []
        try await api.download(file: file, to: destination) { sent, _ in progress.append(sent) }
        XCTAssertEqual(try Data(contentsOf: destination), contents)
        XCTAssertEqual(progress.last, Int64(contents.count))
        XCTAssertGreaterThan(progress.count, 1, "Un archivo de varios trozos informa del avance más de una vez")
    }

    func testATamperedDownloadIsRefusedAndNotLeftBehind() async throws {
        serve()
        let api = client()
        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first { $0.id == "ARCHIVO" })
        // One byte changed anywhere in the file breaks the MAC stored inside its key.
        contents[100] = contents[100] &+ 1
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await api.download(file: file, to: destination) { _, _ in }
            XCTFail("Un contenido alterado no debe aceptarse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("comprobación de integridad"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "No se deja un archivo corrupto en el disco")
    }

    func testAnUploadIsEncryptedBeforeLeavingAndRegisteredWithItsKey() async throws {
        serve()
        let api = client()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data((0..<150_000).map { UInt8($0 % 97) })
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }

        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let checkpoint = UploadCheckpoint(total: Int64(payload.count), modified: stamp)
        let receipt = try await api.resumableUpload(local: source, parent: "root", name: "nuevo.bin", replacing: nil,
                                                    checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "NUEVO")
        XCTAssertEqual(receipt.verification, .unavailable, "Mega guarda la comprobación que calculó iCloudy, no una propia")

        let node = try XCTUnwrap(registered)
        XCTAssertEqual(node["h"] as? String, "RECIBO", "Se registra con el recibo que devolvió la subida")
        let wrapped = MegaCrypto.decode(try XCTUnwrap(node["k"] as? String))
        let key = try MegaCrypto.ecb(wrapped, key: masterKey)
        let parts = try XCTUnwrap(MegaCrypto.unpack(fileKey: key))
        XCTAssertEqual(MegaCrypto.attributes(MegaCrypto.decode(try XCTUnwrap(node["a"] as? String)), key: parts.key)?["n"] as? String,
                       "nuevo.bin", "El nombre también viaja cifrado")

        // What reached the server must be the ciphertext, and must decrypt back to the original bytes.
        let sent = try XCTUnwrap(lastUpload?.body)
        XCTAssertEqual(sent.count, payload.count)
        XCTAssertNotEqual(sent, payload, "El contenido no sale en claro")
        var plain = Data()
        for chunk in MegaCrypto.chunks(of: Int64(payload.count)) {
            let slice = sent[Int(chunk.offset)..<Int(chunk.offset + chunk.length)]
            plain += try MegaCrypto.ctr(Data(slice), key: parts.key, nonce: parts.nonce, blockOffset: UInt64(chunk.offset / 16))
        }
        XCTAssertEqual(plain, payload)
        // And the MAC stored in the key must be the one that content produces, or the file would fail to download.
        let macs = try MegaCrypto.chunks(of: Int64(payload.count)).map { chunk in
            try MegaCrypto.chunkMAC(payload[Int(chunk.offset)..<Int(chunk.offset + chunk.length)], key: parts.key, nonce: parts.nonce)
        }
        XCTAssertEqual(try MegaCrypto.metaMAC(chunks: macs, key: parts.key), parts.mac)
    }

    // MARK: - Changing things and failing well

    func testDeletingMovesToTheBinSoItCanBeUndone() async throws {
        var moved: [String: Any]?
        serve { action, command in
            if action == "m" { moved = command }
            return nil
        }
        let api = client()
        let files = try await api.list(parent: "root")
        let target = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        try await api.trash(file: target)
        XCTAssertEqual(moved?["n"] as? String, "ARCHIVO")
        XCTAssertEqual(moved?["t"] as? String, "PAPELERA", "Se mueve a la papelera, no se borra")
    }

    func testMegaFailuresBecomeSomethingTheUserCanActOn() async throws {
        var attempts = 0
        serve { action, _ in
            guard action == "uq" else { return nil }
            attempts += 1
            // Mega answers -3 while a value is not ready and expects the client to wait rather than to give up.
            return attempts < 3 ? (200, Data("[-3]".utf8)) : (200, Data(#"[{"cstrg":1,"mstrg":2}]"#.utf8))
        }
        let api = client()
        let quota = try await api.storageQuota()
        XCTAssertEqual(attempts, 3, "Se reintenta en lugar de fallar")
        XCTAssertEqual(quota.total, 2)

        serve { action, _ in action == "l" ? (200, Data("[-9]".utf8)) : nil }
        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first { $0.id == "ARCHIVO" })
        do { _ = try await api.publicLink(for: file); XCTFail("Debe informar del error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ya no está en Mega"), error.localizedDescription) }
    }

    func testABareNumberIsAValidAnswerAndNotABrokenResponse() async throws {
        // Mega replies to a rename or a move with the number 0 on its own, and reports "wait" as -3 on its own too.
        // Neither is an array or an object, so a strict JSON parser rejects both and the account looks broken.
        serve { action, _ in action == "a" ? (200, Data("0".utf8)) : nil }
        let api = client()
        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first { $0.id == "ARCHIVO" })
        try await api.rename(file: file, name: "informe nuevo.pdf")

        var attempts = 0
        serve { action, _ in
            guard action == "uq" else { return nil }
            attempts += 1
            return attempts < 2 ? (200, Data("-3".utf8)) : (200, Data(#"[{"cstrg":5,"mstrg":6}]"#.utf8))
        }
        let quota = try await api.storageQuota()
        XCTAssertEqual(attempts, 2, "Un -3 suelto significa «espera», no «respuesta ilegible»")
        XCTAssertEqual(quota.used, 5)
    }

    func testWaitingAndProvingWorkHaveSeparateBudgets() async throws {
        // Both make the same request again, but for different reasons. Sharing one counter meant that solving a
        // proof of work spent the patience meant for a server that had only said "wait", and a delete would report
        // -3 to the user and then work fine when they retried it by hand.
        XCTAssertGreaterThan(MegaAPI.maxWaits, MegaAPI.maxProofs, "Esperar es barato; la prueba de trabajo no")
        let total = (0..<MegaAPI.maxWaits).reduce(0.0) { $0 + Double(MegaAPI.waitDelay($1)) / 1_000_000_000 }
        XCTAssertGreaterThan(total, 20, "Medio segundo cinco veces se quedaba muy corto")
        XCTAssertLessThan(total, 90, "Pero una sola llamada no puede colgarse minutos")
        XCTAssertLessThan(MegaAPI.waitDelay(0), MegaAPI.waitDelay(1), "La espera crece")
        XCTAssertEqual(MegaAPI.waitDelay(20), MegaAPI.waitDelay(21), "Y tiene tope")
    }

    func testABusyServerIsWaitedOutInsteadOfReportedAsAnError() async throws {
        // What the user saw: deleting a file reported -3 several times before finally working.
        var attempts = 0
        serve { action, _ in
            guard action == "m" else { return nil }
            attempts += 1
            return attempts < 4 ? (200, Data("-3".utf8)) : (200, Data("0".utf8))
        }
        let api = client()
        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first { $0.id == "ARCHIVO" })
        try await api.trash(file: file)
        XCTAssertEqual(attempts, 4, "Se espera y se repite hasta que el servidor está listo")
        let after = try await api.list(parent: "root")
        XCTAssertNil(after.first { $0.id == "ARCHIVO" }, "Y el borrado se refleja")
    }

    func testADroppedRequestIsRepeatedInsteadOfLosingTheDelete() async throws {
        // A request that never gets an answer is not Mega saying no. Borrar fallaba a la primera en una conexión
        // con altibajos, y volver a intentarlo a mano funcionaba.
        var attempts = 0
        serve { action, _ in
            guard action == "m" else { return nil }
            attempts += 1
            if attempts < 3 { throw URLError(.networkConnectionLost) }
            return (200, Data("0".utf8))
        }
        let api = client()
        let listed = try await api.list(parent: "root")
        try await api.trash(file: try XCTUnwrap(listed.first { $0.id == "ARCHIVO" }))
        XCTAssertEqual(attempts, 3, "Se repite la petición caída")
        let after = try await api.list(parent: "root")
        XCTAssertNil(after.first { $0.id == "ARCHIVO" }, "Y el borrado se refleja")
    }

    func testAnUnreachableMegaIsSaidSoAndNotAsASystemTimeout() async throws {
        // This is the message the user actually saw: «Se ha agotado el tiempo de espera», the system's own wording
        // for a timeout, which mentions neither Mega nor anything the user can try.
        var attempts = 0
        serve { action, _ in
            guard action == "m" else { return nil }
            attempts += 1
            throw URLError(.cannotConnectToHost)
        }
        let api = client()
        let listed = try await api.list(parent: "root")
        do {
            try await api.trash(file: try XCTUnwrap(listed.first { $0.id == "ARCHIVO" }))
            XCTFail("Debe fallar cuando no se llega a Mega")
        } catch {
            let text = error.localizedDescription
            XCTAssertTrue(text.contains("servidores de Mega"), text)
            XCTAssertTrue(text.contains("mal momento de Mega"), "Se dice primero qué es lo más probable: \(text)")
        }
        XCTAssertEqual(attempts, MegaAPI.maxDrops + 1, "Se insiste, pero un número contado de veces")
    }

    func testWithoutInternetMegaIsNotAskedAgainAndAgain() async throws {
        var attempts = 0
        serve { action, _ in
            guard action == "m" else { return nil }
            attempts += 1
            throw URLError(.notConnectedToInternet)
        }
        let api = client()
        let listed = try await api.list(parent: "root")
        do {
            try await api.trash(file: try XCTUnwrap(listed.first { $0.id == "ARCHIVO" }))
            XCTFail("Debe fallar sin conexión")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no tiene conexión a internet"), error.localizedDescription)
        }
        XCTAssertEqual(attempts, 1, "Repetir sin conexión solo hace esperar más para el mismo resultado")
    }

    func testAServerErrorIsWaitedOutTheSameWayAsABusyOne() async throws {
        var attempts = 0
        serve { action, _ in
            guard action == "m" else { return nil }
            attempts += 1
            return attempts < 3 ? (503, Data()) : (200, Data("0".utf8))
        }
        let api = client()
        let listed = try await api.list(parent: "root")
        try await api.trash(file: try XCTUnwrap(listed.first { $0.id == "ARCHIVO" }))
        XCTAssertEqual(attempts, 3, "Un 5xx es un mal momento de Mega, no un fallo de la cuenta")
    }

    func testOneCommandCannotFreezeTheWindowForMinutes() {
        // Every repeat above shares one clock, so no combination of proofs, waits and dropped requests can leave the
        // user looking at a spinner for minutes.
        // Medido contra los servidores de verdad: sano, Mega contesta en menos de tres segundos, así que esperar un
        // minuto entero por una sola petición era tiempo gastado en una respuesta que no iba a llegar.
        XCTAssertLessThanOrEqual(MegaAPI.requestTimeout, 15, "Una petición sin noticias no espera un minuto entero")
        XCTAssertGreaterThan(MegaAPI.requestTimeout, 5, "Pero con margen de sobra sobre lo que Mega tarda de verdad")
        XCTAssertLessThanOrEqual(MegaAPI.budget, 120)
        let peor = Double(MegaAPI.maxDrops + 1) * MegaAPI.requestTimeout
            + (0...MegaAPI.maxDrops).reduce(0.0) { $0 + Double(MegaAPI.waitDelay($1)) / 1_000_000_000 }
        XCTAssertLessThan(peor, MegaAPI.budget, "Todos los reintentos caben en el reloj, ninguno se queda sin usar")
    }

    func testAProofOfWorkChallengeIsSolvedAndTheRequestRepeated() async throws {
        // Mega guards its account endpoints with a 402 and an empty body. Before this was handled, every sign-in
        // failed with "a response that cannot be understood", which said nothing about what to do.
        let token = "mH7V46ouyOeSYe2ni_kuk9Ec9wgmW3PxVUu-p8TX6aCgBK05XddtJ-ioehg5FB8W"
        var asked = 0
        var proof: String?
        StubProtocol.handler = { request in
            asked += 1
            guard let header = request.value(forHTTPHeaderField: "X-Hashcash") else {
                return (402, ["X-Hashcash": "1:255:1789625745:\(token)"], Data())
            }
            proof = header
            return (200, [:], Data(#"[{"cstrg":7,"mstrg":9}]"#.utf8))
        }
        let quota = try await client().storageQuota()
        XCTAssertEqual(asked, 2, "La misma petición se repite una vez con la prueba resuelta")
        XCTAssertEqual(proof, "1:\(token):AQAAAA")
        XCTAssertEqual(quota.used, 7)
    }

    func testAnExpiredSessionIsReportedAsSuchAndNotAsAnUnknownError() async throws {
        serve { action, _ in action == "f" ? (200, Data("[-15]".utf8)) : nil }
        let api = client()
        var expired = false
        api.sessionDidExpire = { _ in expired = true }
        do { _ = try await api.list(parent: "root"); XCTFail("Debe avisar de la sesión") }
        catch {
            guard case CloudError.sessionExpired = error else { return XCTFail("Otro error: \(error)") }
        }
        XCTAssertTrue(expired, "La cuenta queda marcada para volver a iniciar sesión")
    }

    func testTransferAddressesAreAlwaysRaisedToTLS() {
        // Mega hands out transfer addresses in the clear unless asked otherwise, and macOS refuses to load those.
        XCTAssertEqual(CloudAPI.secureURL("http://gfs1.ejemplo.com/dl/abc")?.absoluteString, "https://gfs1.ejemplo.com/dl/abc")
        XCTAssertEqual(CloudAPI.secureURL("HTTP://gfs1.ejemplo.com/dl")?.scheme, "https", "El esquema puede venir en mayúsculas")
        XCTAssertEqual(CloudAPI.secureURL("https://ya.ejemplo.com/dl")?.absoluteString, "https://ya.ejemplo.com/dl")
        XCTAssertEqual(CloudAPI.secureURL("http://ejemplo.com:8080/dl?x=1")?.absoluteString, "https://ejemplo.com:8080/dl?x=1",
                       "El puerto y los parámetros se conservan")
        XCTAssertNil(CloudAPI.secureURL(""))
        XCTAssertNil(CloudAPI.secureURL("/solo/una/ruta"), "Sin servidor no hay nada que descargar")
    }

    func testAChangeIsAppliedToTheTreeInsteadOfReloadingTheWholeAccount() async throws {
        // Mega sends the entire account in one response. Asking for it again after every rename or move is what made
        // the explorer crawl after each change, so the outcome is applied to what is already here.
        var trees = 0
        serve { action, _ in
            if action == "f" { trees += 1 }
            return nil
        }
        let api = client()
        var files = try await api.list(parent: "root")
        XCTAssertEqual(trees, 1)

        let file = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        try await api.rename(file: file, name: "informe final.pdf")
        files = try await api.list(parent: "root")
        XCTAssertEqual(files.first { $0.id == "ARCHIVO" }?.name, "informe final.pdf")
        XCTAssertEqual(trees, 1, "Renombrar no vuelve a pedir la cuenta entera")

        let renamed = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        try await api.move(file: renamed, to: "CARPETA")
        files = try await api.list(parent: "root")
        XCTAssertNil(files.first { $0.id == "ARCHIVO" }, "Se ha ido de la raíz")
        let inside = try await api.list(parent: "CARPETA")
        XCTAssertEqual(inside.map(\.id), ["ARCHIVO"], "Y está dentro de la carpeta")
        XCTAssertEqual(trees, 1)

        let moved = try XCTUnwrap(inside.first)
        try await api.trash(file: moved)
        let afterTrash = try await api.list(parent: "CARPETA")
        XCTAssertTrue(afterTrash.isEmpty, "Borrar lo saca de la carpeta")
        XCTAssertEqual(trees, 1, "Tampoco mover ni borrar recargan nada")
    }

    func testRenamingKeepsTheOtherAttributesOfTheNode() async throws {
        // MEGAsync stores a fingerprint with the real modification date under `c`. Writing back only the name erased
        // it, and the official clients then lost the date and re-uploaded the file.
        extraAttributes["ARCHIVO"] = ["c": "huella:12345", "lbl": 3]
        var written: [String] = []
        serve { action, command in
            if action == "a" { written.append(command["attr"] as? String ?? "") }
            return nil
        }
        let api = client()
        let files = try await api.list(parent: "root")
        let file = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        try await api.rename(file: file, name: "informe final.pdf")
        let content = try XCTUnwrap(MegaCrypto.unpack(fileKey: fileKey)).key
        let values = try XCTUnwrap(MegaCrypto.attributes(MegaCrypto.decode(try XCTUnwrap(written.first)), key: content))
        XCTAssertEqual(values["n"] as? String, "informe final.pdf")
        XCTAssertEqual(values["c"] as? String, "huella:12345", "La huella sigue ahí")
        XCTAssertEqual(values["lbl"] as? Int, 3)
        // And renaming again starts from the updated set, not from the original.
        let listing = try await api.list(parent: "root")
        let renamed = try XCTUnwrap(listing.first { $0.id == "ARCHIVO" })
        try await api.rename(file: renamed, name: "otro.pdf")
        let again = try XCTUnwrap(MegaCrypto.attributes(MegaCrypto.decode(try XCTUnwrap(written.last)), key: content))
        XCTAssertEqual(again["n"] as? String, "otro.pdf")
        XCTAssertEqual(again["c"] as? String, "huella:12345")
    }

    func testTheTreeIsFetchedAgainOnRefreshAndWhenItGrowsOld() async throws {
        // Mega never says what other devices did. Changes made from iCloudy are applied in place, but "Actualizar"
        // and plain age have to bring the account back from the server, or a file uploaded from the phone is
        // invisible until the account is disconnected.
        var trees = 0
        serve { action, _ in
            if action == "f" { trees += 1 }
            return nil
        }
        let api = client()
        _ = try await api.list(parent: "root")
        _ = try await api.list(parent: "root")
        XCTAssertEqual(trees, 1, "Navegar no vuelve a pedir la cuenta")
        api.dropCaches()
        _ = try await api.list(parent: "root")
        XCTAssertEqual(trees, 2, "Actualizar sí")
        api.megaStateCache?.loadedAt = Date().addingTimeInterval(-CloudAPI.megaTreeMaxAge - 1)
        _ = try await api.list(parent: "root")
        XCTAssertEqual(trees, 3, "Y un árbol viejo se renueva solo")
        XCTAssertEqual(api.megaStateCache?.sid, session, "Sin volver a iniciar sesión")
    }

    func testACreatedFolderAppearsWithoutAskingForTheAccountAgain() async throws {
        var trees = 0
        serve { action, command in
            if action == "f" { trees += 1 }
            guard action == "p" else { return nil }
            // Mega answers with the node it created, which is everything needed to place it in the tree.
            let entry = (command["n"] as? [[String: Any]])?.first ?? [:]
            // The real answer carries the key prefixed with the owner's handle, as every node does.
            return (200, try JSONSerialization.data(withJSONObject: [[
                "f": [["h": "NUEVA", "p": command["t"] as? String ?? "", "t": 1,
                       "a": entry["a"] as? String ?? "", "k": "PROPIA:" + (entry["k"] as? String ?? ""),
                       "ts": 1_700_000_100]]]]))
        }
        let api = client()
        _ = try await api.list(parent: "root")
        let handle = try await api.createFolder(name: "Contratos", parent: "root")
        XCTAssertEqual(handle, "NUEVA")
        let files = try await api.list(parent: "root")
        XCTAssertEqual(files.first { $0.id == "NUEVA" }?.name, "Contratos", "El nombre se descifra de lo que devolvió")
        XCTAssertTrue(try XCTUnwrap(files.first { $0.id == "NUEVA" }).isFolder)
        XCTAssertEqual(trees, 1)
    }

    func testAnUploadPieceIsRetriedWhenTheStorageServerSaysWait() async throws {
        // The storage servers answer -3 the same way the API does. Giving up on that loses the whole upload over a
        // moment's delay, which is what the transfer list was showing as a failure.
        serve()
        uploadRefusals = 1
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let payload = Data("un archivo pequeño".utf8)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let checkpoint = UploadCheckpoint(total: Int64(payload.count), modified: stamp)

        let receipt = try await client().resumableUpload(local: source, parent: "root", name: "nota.txt", replacing: nil,
                                                         checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(uploadRefusals, 0, "El trozo se reenvió después de la espera")
        XCTAssertEqual(receipt.remoteID, "NUEVO")
    }

    func testAFolderSharedIntoTheAccountIsReadableInsteadOfUnavailable() async throws {
        // An item shared in is wrapped with the key of the share it arrived in, not with the master key. Without
        // reading the `ok` array of the same response, every one of them showed up as "Elemento sin acceso".
        serve()
        let files = try await client().list(parent: "root")
        let shared = try XCTUnwrap(files.first { $0.id == "COMPARTIDO" })
        XCTAssertEqual(shared.name, "De Ana")
        XCTAssertTrue(shared.isFolder)
        // And something genuinely unreadable still says so rather than inventing a name.
        let foreign = try XCTUnwrap(files.first { $0.id == "AJENO" })
        XCTAssertEqual(foreign.name, "Elemento sin acceso")
    }

    func testAnUnknownAddressAtSignInIsNotAMissingFile() async throws {
        // -9 means one thing signing in and another everywhere else. Telling somebody who mistyped their e-mail
        // that the item is gone sent them looking for a file they never deleted.
        XCTAssertTrue(MegaAPI.failure(-9, command: "us0").localizedDescription.contains("no reconoce ese correo"))
        XCTAssertTrue(MegaAPI.failure(-9, command: "us").localizedDescription.contains("no reconoce ese correo"))
        XCTAssertTrue(MegaAPI.failure(-9, command: "g").localizedDescription.contains("ya no está"))
        XCTAssertTrue(MegaAPI.failure(-9).localizedDescription.contains("ya no está"))

        StubProtocol.handler = { _ in (200, [:], Data("[-9]".utf8)) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        do {
            _ = try await MegaAPI.signIn(email: "nadie@ejemplo.com", password: "x", code: nil,
                                          session: URLSession(configuration: configuration))
            XCTFail("Una cuenta que no existe debe decirlo")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no reconoce ese correo"), error.localizedDescription) }
    }

    func testTwoListingsAtOnceDownloadTheAccountOnlyOnce() async throws {
        // Opening the app starts a listing and a quota check together, and both want the tree. On a large account
        // that meant downloading and decrypting the whole thing twice, side by side.
        var trees = 0
        serve { action, _ in
            if action == "f" { trees += 1 }
            return nil
        }
        let api = client()
        async let first = api.list(parent: "root")
        async let second = api.list(parent: "root")
        async let third = api.searchPage(term: "informe")
        let (a, b, c) = try await (first, second, third)
        XCTAssertEqual(trees, 1, "Una sola petición del árbol entre las tres")
        XCTAssertFalse(a.isEmpty)
        XCTAssertEqual(a.map(\.id), b.map(\.id))
        XCTAssertFalse(c.hits.isEmpty)
    }

    func testADownloadSurvivesAnAddressThatExpiredHalfway() async throws {
        // The temporary address has a life of its own, shorter than a large download, and a chunk that fails used to
        // lose the whole file: no retry, and nothing that noticed the address had gone stale.
        var refusals = 1
        var addresses = 0
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            if url.host == "g.api.mega.co.nz" {
                let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
                switch command["a"] as? String {
                case "f": return (200, [:], try JSONSerialization.data(withJSONObject: [["f": try tree(), "ok": try shares()]]))
                case "g":
                    addresses += 1
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["g": "http://descarga.ejemplo.com/token\(addresses)", "s": contents.count]]))
                default: return (200, [:], Data("[0]".utf8))
                }
            }
            if refusals > 0 { refusals -= 1; return (403, [:], Data()) }
            let range = url.lastPathComponent.split(separator: "-").compactMap { Int($0) }
            let bounds = try XCTUnwrap(range.count == 2 ? range : nil)
            let parts = try XCTUnwrap(MegaCrypto.unpack(fileKey: fileKey))
            let cipher = try MegaCrypto.ctr(Data(contents[bounds[0]...bounds[1]]), key: parts.key, nonce: parts.nonce,
                                            blockOffset: UInt64(bounds[0] / 16))
            return (200, [:], cipher)
        }
        let api = client()
        let files = try await api.list(parent: "root")
        let file = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await api.download(file: file, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), contents, "El archivo llega entero pese al tropiezo")
        XCTAssertGreaterThan(addresses, 1, "Y se pidió una dirección nueva")
    }

    func testAnExhaustedTransferQuotaSaysWhatItIs() async throws {
        // 509 is Mega's own code for a free account that has spent its allowance. It arrived as a bare HTTP code.
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            if url.host == "g.api.mega.co.nz" {
                let command = try XCTUnwrap((try JSONSerialization.jsonObject(with: requestData(request)) as? [[String: Any]])?.first)
                if command["a"] as? String == "f" { return (200, [:], try JSONSerialization.data(withJSONObject: [["f": try tree(), "ok": try shares()]])) }
                return (200, [:], try JSONSerialization.data(withJSONObject: [["g": "http://descarga.ejemplo.com/t", "s": contents.count]]))
            }
            return (509, [:], Data())
        }
        let api = client()
        let files = try await api.list(parent: "root")
        let file = try XCTUnwrap(files.first { $0.id == "ARCHIVO" })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do { try await api.download(file: file, to: destination); XCTFail("Sin cuota no hay descarga") }
        catch { XCTAssertTrue(error.localizedDescription.contains("cuota de transferencia"), error.localizedDescription) }
    }

    func testAnEmptyFileIsUploadedAndRegisteredLikeAnyOther() async throws {
        // A file of zero bytes has no chunks at all, so the loop that encrypts them has nothing to iterate and the
        // token that turns an upload into a node has to come from the one request that is still made.
        serve()
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var saved: [UploadCheckpoint] = []
        let receipt = try await client().resumableUpload(local: source, parent: "root", name: "vacio.txt", replacing: nil,
                                                         checkpoint: UploadCheckpoint(total: 0, modified: stamp),
                                                         save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "NUEVO")
        XCTAssertEqual(lastUpload?.offset, 0)
        XCTAssertTrue(saved.last?.complete == true)
        XCTAssertNotNil(registered?["a"], "Se registra con su nombre cifrado como cualquier otro")
    }

    func testTheAccountTreeIsGivenMoreTimeThanAnOrdinaryCommand() {
        // An account with hundreds of thousands of nodes takes a while before it starts answering `f`, and the
        // ordinary margin cut it off before the first byte arrived.
        XCTAssertGreaterThan(MegaAPI.treeTimeout, MegaAPI.requestTimeout)
        XCTAssertLessThanOrEqual(MegaAPI.treeTimeout, MegaAPI.budget)
    }

    func testWorkRunOffTheMainActorStopsWhenTheTaskIsCancelled() async throws {
        // The proof of work Mega asks for runs off the main actor, and a detached task inherits no cancellation.
        // Its own check never fired, so a hard challenge kept a core busy with no way to stop it.
        let job = Task { () -> Bool in
            try await blockingIO {
                let deadline = Date().addingTimeInterval(5)
                while Date() < deadline { try Task.checkCancellation() }
                return false        // ran the full five seconds without ever noticing
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        job.cancel()
        do { _ = try await job.value; XCTFail("La cancelación tiene que llegar") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testCapabilitiesSayWhatMegaCanAndCannotDo() {
        let mega = Cloud.mega.capabilities
        XCTAssertTrue(mega.search, "El árbol entero ya está aquí, así que buscar no cuesta una petición")
        XCTAssertTrue(mega.publicLinks)
        XCTAssertTrue(mega.reversibleTrash, "Borrar mueve a la papelera de Mega")
        XCTAssertTrue(mega.copy)
        XCTAssertTrue(mega.quota)
        XCTAssertFalse(mega.oauth)
        XCTAssertFalse(mega.checksum, "La única comprobación que Mega guarda es la que calculó iCloudy")
        XCTAssertFalse(mega.recents)
        XCTAssertTrue(Cloud.mega.isExperimental, "La interfaz debe decirlo: Mega no publica ni sostiene esta API")
        XCTAssertFalse(Cloud.google.isExperimental)
        XCTAssertTrue(Cloud.mega.usesPasswordLogin)
        XCTAssertFalse(Cloud.mega.isSelfHosted, "No es un servidor del usuario aunque se conecte con contraseña")
    }

    // MARK: - Helpers

    /// Mega's multi-precision encoding: bit length, then the bytes.
    private static func integer(_ value: MegaBigInt) -> Data {
        let bytes = value.data
        let bits = value.bitWidth
        return Data([UInt8(bits >> 8), UInt8(bits & 0xFF)]) + bytes
    }
    /// A real 512-bit RSA key, generated outside iCloudy so the challenge can only be answered with the private half.
    /// Small on purpose: the arithmetic is checked against a reference implementation elsewhere, and this keeps the
    /// sign-in test quick.
    private static let primeP = MegaBigInt(Data([
        0xCF, 0xD0, 0xBE, 0xA5, 0x07, 0xB9, 0x07, 0x7D, 0x42, 0xBB, 0x9C, 0x0F,
        0xB2, 0x0B, 0x06, 0x4D, 0xA9, 0x2C, 0x8F, 0x72, 0x19, 0x3F, 0x34, 0x29,
        0xBA, 0x7C, 0x56, 0x9C, 0x99, 0x11, 0x32, 0xC1]))
    private static let primeQ = MegaBigInt(Data([
        0xB8, 0xED, 0x5C, 0xC8, 0x3E, 0x6A, 0x14, 0xA2, 0xC8, 0x0D, 0x57, 0x90,
        0x95, 0x28, 0x04, 0xF2, 0x95, 0x79, 0x32, 0xFD, 0x4D, 0xD8, 0x62, 0x9A,
        0x49, 0x5F, 0x6F, 0x93, 0x90, 0x03, 0xCB, 0xC9]))
    private static let privateExponent = MegaBigInt(Data([
        0x8D, 0x4A, 0x17, 0x26, 0x49, 0xF8, 0x86, 0x58, 0x54, 0x7C, 0x2F, 0xCC,
        0x40, 0x86, 0xBD, 0x66, 0x20, 0xE4, 0xDE, 0xD4, 0xEF, 0xDE, 0xB5, 0xC3,
        0x5E, 0x0D, 0x5B, 0x1F, 0x3E, 0x17, 0xFD, 0xDE, 0x7C, 0x3C, 0x49, 0xBC,
        0x95, 0x2E, 0x64, 0x14, 0x9E, 0x7E, 0x18, 0xC5, 0xBA, 0x96, 0xF7, 0xA0,
        0xCD, 0x9A, 0x78, 0xAF, 0x03, 0x66, 0xE7, 0xCF, 0x5D, 0x11, 0x9A, 0x16,
        0x6A, 0x49, 0x50, 0xF1]))
    private static let publicExponent = MegaBigInt(17)
}
