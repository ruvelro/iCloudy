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

    private func entry(_ handle: String, parent: String, kind: Int, name: String, key: Data,
                       size: Int? = nil, master: Data? = nil) throws -> [String: Any] {
        let content = kind == 0 ? (MegaCrypto.unpack(fileKey: key)?.key ?? Data()) : key
        var node: [String: Any] = ["h": handle, "p": parent, "t": kind, "ts": 1_700_000_000,
                                   "a": MegaCrypto.encode(try MegaCrypto.encodeAttributes(["n": name], key: content)),
                                   "k": "PROPIA:" + MegaCrypto.encode(try MegaCrypto.ecb(key, key: master ?? masterKey, encrypt: true))]
        if let size { node["s"] = size }
        return node
    }
    private func tree() throws -> [[String: Any]] {
        [["h": "RAIZ", "p": "", "t": 2, "ts": 1_700_000_000],
         ["h": "PAPELERA", "p": "", "t": 4, "ts": 1_700_000_000],
         try entry("CARPETA", parent: "RAIZ", kind: 1, name: "Documentos", key: Data((1...16).map { UInt8($0 * 3) })),
         try entry("ARCHIVO", parent: "RAIZ", kind: 0, name: "informe.pdf", key: fileKey, size: contents.count),
         // Shared into the account with a key this account cannot unwrap.
         try entry("AJENO", parent: "RAIZ", kind: 0, name: "de otro.txt", key: MegaCrypto.randomKey(),
                   size: 10, master: Data(repeating: 9, count: 16)),
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
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["f": try tree(), "sn": "xyz"]]))
                case "g":
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["g": "https://descarga.ejemplo.com/token", "s": contents.count]]))
                case "u":
                    return (200, [:], try JSONSerialization.data(withJSONObject: [["p": "https://subida.ejemplo.com/destino"]]))
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
                // The path carries the byte range, the way Mega's temporary links work.
                let range = url.lastPathComponent.split(separator: "-").compactMap { Int($0) }
                let bounds = try XCTUnwrap(range.count == 2 ? range : nil)
                let parts = try XCTUnwrap(MegaCrypto.unpack(fileKey: fileKey))
                let slice = contents[bounds[0]...bounds[1]]
                let cipher = try MegaCrypto.ctr(Data(slice), key: parts.key, nonce: parts.nonce, blockOffset: UInt64(bounds[0] / 16))
                return (200, [:], cipher)
            }
            if url.host == "subida.ejemplo.com" {
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
        XCTAssertEqual(files.map(\.name), ["Documentos", "Elemento sin acceso", "informe.pdf"], "Carpetas primero y luego por nombre")
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
        api.sessionDidExpire = { expired = true }
        do { _ = try await api.list(parent: "root"); XCTFail("Debe avisar de la sesión") }
        catch {
            guard case CloudError.sessionExpired = error else { return XCTFail("Otro error: \(error)") }
        }
        XCTAssertTrue(expired, "La cuenta queda marcada para volver a iniciar sesión")
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
