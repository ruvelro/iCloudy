import XCTest
@testable import iCloudy

/// Telegram's Bot API is documented and stable, unlike Mega's or O2's. What these tests pin down is the part iCloudy
/// invents on top of it: cutting files into parts under the 20 MB download ceiling, and keeping the whole tree in a
/// JSON document pinned in the channel. The stand-in below is a channel that behaves the way the documentation says
/// one does; it cannot prove Telegram will keep allowing this, which is what the experimental label is for.
@MainActor
final class TelegramTests: XCTestCase {
    private let token = "123456789:AAH0abcdefghijklmnopqrstuvwxyz01234"
    private let chat = "-1001234567890"

    /// The channel: documents by identifier, which message carries which, and which one is pinned.
    private var stored: [String: Data] = [:]
    private var names: [String: String] = [:]
    private var fingerprints: [String: String] = [:]
    private var messages: [Int: String] = [:]
    private var pinnedMessage: Int?
    private var nextMessage = 100
    private var nextFile = 1
    private var calls: [String] = []

    override func setUp() {
        stored = [:]; names = [:]; fingerprints = [:]; messages = [:]
        pinnedMessage = nil; nextMessage = 100; nextFile = 1; calls = []
    }
    override func tearDown() {
        StubProtocol.handler = nil
        TelegramLimits.part = 19 * 1024 * 1024
        TelegramLimits.spacing = 3
    }
    /// Parts of a few hundred bytes, and no pacing: otherwise a three-part upload would take nine seconds of
    /// sleeping and forty megabytes of stubbed traffic to prove the same thing.
    private func shrinkParts(to size: Int64 = 512) {
        TelegramLimits.part = size
        TelegramLimits.spacing = 0
    }

    // MARK: - The channel

    private func envelope(_ result: Any) -> (Int, [String: String], Data) {
        (200, [:], (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": result])) ?? Data())
    }
    private func refusal(_ code: Int, _ text: String) -> (Int, [String: String], Data) {
        let body: [String: Any] = ["ok": false, "error_code": code, "description": text]
        return (code, [:], (try? JSONSerialization.data(withJSONObject: body)) ?? Data())
    }
    private func message(_ id: Int) -> [String: Any] {
        guard let file = messages[id], let bytes = stored[file] else { return ["message_id": id] }
        return ["message_id": id,
                "document": ["file_id": file, "file_unique_id": fingerprints[file] ?? "",
                             "file_name": names[file] ?? "", "file_size": bytes.count]]
    }
    /// Files the channel is seeded with, before iCloudy has said anything.
    @discardableResult
    private func place(_ payload: Data, named name: String) -> (file: String, message: Int) {
        let file = "file-\(nextFile)"; nextFile += 1
        let id = nextMessage; nextMessage += 1
        stored[file] = payload; names[file] = name
        fingerprints[file] = "u-\(file)-\(payload.count)"
        messages[id] = file
        return (file, id)
    }

    private func serve(_ intercept: ((String, [String: String]) -> (Int, [String: String], Data)?)? = nil) {
        StubProtocol.handler = { [self] request in
            let url = try XCTUnwrap(request.url)
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
            // The token addresses the bot in the path. Sending it as a bearer header would hand it to whatever the
            // generic request builder does next, redirects included.
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "El token no viaja en una cabecera")
            XCTAssertEqual(url.host, "api.telegram.org")

            if url.path.hasPrefix("/file/bot") {
                let file = String(url.path.split(separator: "/").last ?? "")
                calls.append("descarga")
                guard let bytes = stored[file] else { return (404, [:], Data()) }
                return (200, [:], bytes)
            }
            let prefix = "/bot\(token)/"
            guard url.path.hasPrefix(prefix) else {
                XCTFail("Ruta inesperada: la petición no se dirige a este bot")
                return (404, [:], Data())
            }
            let method = String(url.path.dropFirst(prefix.count))
            calls.append(method)
            if let answer = intercept?(method, query) { return answer }

            switch method {
            case "getMe":
                return envelope(["id": 123_456_789, "username": "cajon_bot"])
            case "getChat":
                var chatInfo: [String: Any] = ["id": -1_001_234_567_890, "type": "channel", "title": "Cajón"]
                if let pinnedMessage { chatInfo["pinned_message"] = message(pinnedMessage) }
                return envelope(chatInfo)
            case "getChatMember":
                return envelope(["status": "administrator", "can_post_messages": true])
            case "getFile":
                let file = query["file_id"] ?? ""
                guard stored[file] != nil else { return refusal(400, "Bad Request: file not found") }
                return envelope(["file_id": file, "file_path": "documents/" + file])
            case "pinChatMessage":
                pinnedMessage = Int(query["message_id"] ?? "")
                return envelope(true)
            case "sendDocument", "editMessageMedia":
                let type = request.value(forHTTPHeaderField: "Content-Type") ?? ""
                let boundary = try XCTUnwrap(type.components(separatedBy: "boundary=").last)
                let pieces = Self.multipart(requestData(request), boundary: boundary)
                XCTAssertEqual(pieces.first { $0.name == "chat_id" }.map { String(decoding: $0.payload, as: UTF8.self) }, chat)
                let carried = try XCTUnwrap(pieces.first { $0.filename != nil }, "Falta la parte con el archivo")
                let file = "file-\(nextFile)"; nextFile += 1
                stored[file] = carried.payload
                names[file] = carried.filename
                fingerprints[file] = "u-\(file)-\(carried.payload.count)"
                let id: Int
                if method == "editMessageMedia" {
                    let field = pieces.first { $0.name == "message_id" }.map { String(decoding: $0.payload, as: UTF8.self) }
                    id = try XCTUnwrap(Int(field ?? ""), "Editar exige decir qué mensaje")
                } else {
                    id = nextMessage; nextMessage += 1
                }
                messages[id] = file
                return envelope(message(id))
            case "deleteMessage", "deleteMessages":
                XCTFail("iCloudy no borra mensajes de un canal, nunca")
                return envelope(true)
            default:
                XCTFail("Método del Bot API que iCloudy no debería llamar: \(method)")
                return (404, [:], Data())
            }
        }
    }

    private func clientAndStore(secret: String = "") -> (CloudAPI, MemoryCredentials) {
        let store = MemoryCredentials()
        store.stored["telegram:" + chat] = Credential(accessToken: token, refreshToken: "",
                                                      expires: .distantFuture, secret: secret)
        let configuration = StubProtocol.configuration()
        let account = Account(id: "telegram:" + chat, cloud: .telegram, name: "Cajón",
                              email: "@cajon_bot · Cajón", clientID: "", clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: ["chat": chat, "bot": "cajon_bot"])
        return (CloudAPI(account: account, session: URLSession(configuration: configuration), credentials: store), store)
    }
    private func client() -> CloudAPI { clientAndStore().0 }

    /// Uploads a payload and answers with what the tree says about it afterwards.
    @discardableResult
    private func upload(_ api: CloudAPI, _ payload: Data, named name: String, parent: String = "root") async throws -> UploadReceipt {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let checkpoint = UploadCheckpoint(total: Int64(payload.count), modified: stamp)
        return try await api.resumableUpload(local: source, parent: parent, name: name, replacing: nil,
                                             checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
    }
    /// The tree as it stands in the channel, read back from the pinned message rather than from iCloudy's memory.
    private func pinnedIndex() throws -> TelegramIndex {
        let id = try XCTUnwrap(pinnedMessage, "No hay nada fijado en el canal")
        let file = try XCTUnwrap(messages[id])
        XCTAssertEqual(names[file], TelegramLimits.indexName)
        return try TelegramIndex.decode(try XCTUnwrap(stored[file]))
    }

    // MARK: - What the limits have to be

    func testThePartsStayUnderWhatABotIsAllowedToDownload() {
        // The whole shape of this provider follows from this number: a bot downloads at most 20 MB per getFile,
        // however much it managed to upload. A part above it would be stored and never readable again.
        XCTAssertLessThan(TelegramLimits.part, 20_000_000, "Un trozo que no se pueda bajar es un trozo perdido")
        XCTAssertLessThanOrEqual(TelegramLimits.part, 50 * 1024 * 1024, "Y tampoco puede superar lo que se puede subir")
        XCTAssertGreaterThan(TelegramLimits.part, 8 * 1024 * 1024, "Trozos pequeños son mensajes de más, y el límite es por minuto")
        // Twenty messages a minute to the same chat is the documented ceiling.
        XCTAssertGreaterThanOrEqual(TelegramLimits.spacing, 3, "Menos de tres segundos pasa de veinte mensajes por minuto")
    }

    // MARK: - Connecting

    func testAChannelIsAcceptedInEveryShapeSomebodyMightPasteIt() {
        XCTAssertEqual(TelegramAuthentication.telegramChat("-1001234567890"), "-1001234567890")
        XCTAssertEqual(TelegramAuthentication.telegramChat("  -1001234567890 "), "-1001234567890")
        XCTAssertEqual(TelegramAuthentication.telegramChat("@mi_canal"), "@mi_canal")
        XCTAssertEqual(TelegramAuthentication.telegramChat("mi_canal"), "@mi_canal")
        XCTAssertEqual(TelegramAuthentication.telegramChat("https://t.me/mi_canal"), "@mi_canal")
        // The link Telegram itself offers for a private channel hides the identifier behind "-100".
        XCTAssertEqual(TelegramAuthentication.telegramChat("https://t.me/c/1234567890/45"), "-1001234567890")
        XCTAssertNil(TelegramAuthentication.telegramChat(""))
        XCTAssertNil(TelegramAuthentication.telegramChat("ab"))
        XCTAssertNil(TelegramAuthentication.telegramChat("con espacios"))
    }
    func testAHalfCopiedTokenIsRefusedBeforeAnythingLeavesTheMac() async {
        StubProtocol.handler = { _ in XCTFail("Un token con mala pinta no se envía a ninguna parte"); return (500, [:], Data()) }
        defer { StubProtocol.handler = nil }
        XCTAssertTrue(TelegramAuthentication.isTelegramToken(token))
        XCTAssertFalse(TelegramAuthentication.isTelegramToken("123456789"), "Falta el secreto")
        XCTAssertFalse(TelegramAuthentication.isTelegramToken("AAH0abcdefghijklmnopqrstuv"), "Falta el identificador")
        XCTAssertFalse(TelegramAuthentication.isTelegramToken("123456789:corto"))
        do {
            _ = try await TelegramAuthentication().signInTelegram(channel: "-1001234567890", token: "123456789")
            XCTFail("Se aceptó medio token")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("BotFather"), error.localizedDescription)
        }
    }
    func testABotThatIsNotAdministratorIsRefusedAtTheDoorAndNotLater() async throws {
        // A bot merely added to a channel sees nothing and writes nothing. Finding that out on the first upload,
        // with the account already stored and looking healthy, is the worst possible moment.
        serve { method, _ in
            guard method == "getChatMember" else { return nil }
            return (200, [:], (try? JSONSerialization.data(withJSONObject: ["ok": true, "result": ["status": "member"]])) ?? Data())
        }
        let configuration = StubProtocol.configuration()
        let oauth = TelegramAuthentication(session: URLSession(configuration: configuration))
        do {
            _ = try await oauth.signInTelegram(channel: chat, token: token)
            XCTFail("Un bot sin permisos no debe quedar conectado")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("administrador"), error.localizedDescription)
        }
    }

    // MARK: - The pinned index

    func testTheTreeIsReadFromTheMessagePinnedInTheChannel() async throws {
        let tree = TelegramIndex(version: 1, updated: Date(), nodes: [
            TelegramNode(id: "n1", parent: "root", name: "Fotos", folder: true),
            TelegramNode(id: "n2", parent: "n1", name: "playa.jpg", folder: false, size: 40, mime: "image/jpeg"),
            TelegramNode(id: "n3", parent: "root", name: "borrado.txt", folder: false, size: 5, deleted: Date())
        ])
        let seeded = place(try tree.encode(), named: TelegramLimits.indexName)
        pinnedMessage = seeded.message
        serve()

        let api = client()
        let top = try await api.list(parent: "root")
        XCTAssertEqual(top.map(\.name), ["Fotos"], "Lo que está en la papelera no se lista")
        let inside = try await api.list(parent: "n1")
        XCTAssertEqual(inside.map(\.name), ["playa.jpg"])
        // Nothing was asked of Telegram beyond the chat and the index itself: the tree is local from then on.
        XCTAssertEqual(calls, ["getChat", "getFile", "descarga"])
        let found = try await api.searchPage(term: "playa")
        XCTAssertEqual(found.hits.count, 1)
        XCTAssertEqual(calls.count, 3, "Buscar no cuesta ni una petición")
    }
    func testAnIndexSomebodyUnpinnedIsPinnedAgainInsteadOfEmptyingTheAccount() async throws {
        shrinkParts()
        serve()
        let (first, store) = clientAndStore()
        try await upload(first, Data("una nota".utf8), named: "nota.txt")
        let saved = try XCTUnwrap(store.stored["telegram:" + chat]).secret
        XCTAssertFalse(saved.isEmpty, "Dónde quedó el índice se recuerda en el Llavero")

        // Somebody pins a message of their own in the channel. The index is still there, untouched.
        let noise = place(Data("hola".utf8), named: "aviso.txt")
        pinnedMessage = noise.message
        calls = []

        let second = CloudAPI(account: first.account, session: first.session, credentials: store)
        let listed = try await second.list(parent: "root")
        XCTAssertEqual(listed.map(\.name), ["nota.txt"], "El árbol se recupera en lugar de empezar vacío")
        XCTAssertTrue(calls.contains("pinChatMessage"), "Se vuelve a fijar el índice que se recuerda")
    }
    func testAPinnedMessageThatIsNotTheIndexStopsEverythingInsteadOfStartingOver() async throws {
        // Starting from an empty tree here would orphan every file in the channel and then write that emptiness
        // back over the real index. Refusing is the only safe answer.
        let noise = place(Data("hola".utf8), named: "aviso.txt")
        pinnedMessage = noise.message
        serve()
        do {
            _ = try await client().list(parent: "root")
            XCTFail("Un mensaje fijado ajeno no puede pasar por un índice")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("icloudy-index.json"), error.localizedDescription)
        }
    }
    func testAnIndexChangedByAnotherMacIsNotOverwritten() async throws {
        shrinkParts()
        serve()
        let api = client()
        try await upload(api, Data("una nota".utf8), named: "nota.txt")

        // Another Mac writes to the channel: same message, different document behind it.
        let current = try XCTUnwrap(messages[try XCTUnwrap(pinnedMessage)])
        fingerprints[current] = "escrito-por-otro"
        do {
            _ = try await api.createFolder(name: "Carpeta", parent: "root")
            XCTFail("No se puede escribir encima de un índice más nuevo")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("otro equipo"), error.localizedDescription)
        }
        XCTAssertEqual(try pinnedIndex().nodes.count, 1, "Y el índice del canal se queda como estaba")
        let shown = try await api.list(parent: "root")
        XCTAssertEqual(shown.map(\.name), ["nota.txt"], "La vista tampoco se queda con la carpeta que no llegó a existir")
    }

    // MARK: - Contents

    func testAnUploadIsCutIntoPartsAndTheTreeIsWrittenOnceAtTheEnd() async throws {
        shrinkParts(to: 512)
        serve()
        let api = client()
        let payload = Data((0..<1300).map { UInt8($0 % 251) })
        let receipt = try await upload(api, payload, named: "grande.bin")
        XCTAssertEqual(receipt.verification, .verified, "La huella es de iCloudy, y la descarga la comprueba")

        let sent = calls.filter { $0 == "sendDocument" }
        XCTAssertEqual(sent.count, 4, "Tres trozos de contenido y el índice")
        XCTAssertEqual(calls.filter { $0 == "editMessageMedia" }.count, 0, "El primer índice se envía, no se edita")

        let tree = try pinnedIndex()
        let node = try XCTUnwrap(tree.nodes.first { $0.name == "grande.bin" })
        XCTAssertEqual(node.size, 1300)
        XCTAssertEqual(node.parts.map(\.size), [512, 512, 276], "Todo lo que se sube cabe bajo el techo de bajada")
        let source = try Self.write(payload)
        defer { try? FileManager.default.removeItem(at: source) }
        let digest = try await TelegramProvider.telegramDigest(of: source)
        XCTAssertEqual(node.sha256, digest)
        // Each part is named after the file, which is what makes a rescue from the Telegram app possible.
        XCTAssertEqual(node.parts.compactMap { names[$0.fileID] }, ["grande.bin.001", "grande.bin.002", "grande.bin.003"])
        // And the bytes in the channel are the bytes of the file, in order.
        let rebuilt = node.parts.compactMap { stored[$0.fileID] }.reduce(Data(), +)
        XCTAssertEqual(rebuilt, payload)
    }
    func testASingleFileKeepsItsOwnNameInTheChannel() async throws {
        shrinkParts(to: 4096)
        serve()
        let api = client()
        try await upload(api, Data("corto".utf8), named: "nota.txt")
        let node = try XCTUnwrap(try pinnedIndex().nodes.first)
        XCTAssertEqual(node.parts.count, 1)
        XCTAssertEqual(names[try XCTUnwrap(node.parts.first).fileID], "nota.txt", "Un solo trozo no lleva sufijo")
    }
    func testAFileMakesTheRoundTripThroughTheChannelUnchanged() async throws {
        shrinkParts(to: 512)
        serve()
        let api = client()
        let payload = Data((0..<1300).map { UInt8(($0 * 7) % 251) })
        try await upload(api, payload, named: "grande.bin")

        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var seen: [Int64] = []
        try await api.download(file: file, to: destination, progress: { bytes, _ in seen.append(bytes) })
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(seen.last, 1300, "El avance llega hasta el final")
        XCTAssertGreaterThan(seen.count, 1, "Y se informa trozo a trozo, no solo al terminar")
    }
    func testATamperedPartIsCaughtAndLeavesNoFileBehind() async throws {
        shrinkParts(to: 512)
        serve()
        let api = client()
        let payload = Data((0..<1300).map { UInt8($0 % 251) })
        try await upload(api, payload, named: "grande.bin")

        // One byte changed in the channel, keeping the size: only the digest can catch this.
        let node = try XCTUnwrap(try pinnedIndex().nodes.first)
        let victim = try XCTUnwrap(node.parts.last).fileID
        var damaged = try XCTUnwrap(stored[victim])
        damaged[10] = damaged[10] &+ 1
        stored[victim] = damaged

        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        do {
            try await api.download(file: file, to: destination, progress: { _, _ in })
            XCTFail("Un contenido alterado no debe aceptarse")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("huella"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "No se deja media descarga en el disco")
    }
    func testAnEmptyFileIsAnEntryAndNotAMessage() async throws {
        shrinkParts()
        serve()
        let api = client()
        try await upload(api, Data(), named: "vacio.txt")
        XCTAssertEqual(calls.filter { $0 == "sendDocument" }.count, 1, "Solo el índice: Telegram rechaza un documento vacío")
        let node = try XCTUnwrap(try pinnedIndex().nodes.first)
        XCTAssertEqual(node.size, 0)
        XCTAssertTrue(node.parts.isEmpty)
    }

    // MARK: - Changing the tree

    func testCopyingSendsNothingAndPointsAtTheSameMessages() async throws {
        shrinkParts(to: 512)
        serve()
        let api = client()
        let payload = Data((0..<1300).map { UInt8($0 % 251) })
        try await upload(api, payload, named: "grande.bin")
        let folder = try await api.createFolder(name: "Copias", parent: "root")
        calls = []

        let top = try await api.list(parent: "root")
        let original = try XCTUnwrap(top.first { !$0.isFolder })
        try await api.copy(file: original, to: folder)
        XCTAssertEqual(calls.filter { $0 == "sendDocument" }.count, 0, "Copiar no sube un solo byte")

        let tree = try pinnedIndex()
        let copies = tree.nodes.filter { $0.name == "grande.bin" }
        XCTAssertEqual(copies.count, 2)
        XCTAssertNotEqual(copies[0].id, copies[1].id, "Son dos entradas distintas")
        XCTAssertEqual(copies[0].parts, copies[1].parts, "Y apuntan a los mismos mensajes")
    }
    func testTheBinStopsListingAnItemWithoutDeletingASingleMessage() async throws {
        shrinkParts()
        serve()
        let api = client()
        try await upload(api, Data("una nota".utf8), named: "nota.txt")
        let node = try XCTUnwrap(try pinnedIndex().nodes.first)
        let carrier = try XCTUnwrap(node.parts.first).fileID

        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first)
        try await api.trash(file: file)
        let afterwards = try await api.list(parent: "root")
        XCTAssertTrue(afterwards.isEmpty, "Deja de aparecer")
        XCTAssertNotNil(stored[carrier], "Pero el mensaje sigue en el canal, para la app de Telegram")
        // `deleteMessage` would have failed the stub outright; this says why that matters.
        XCTAssertFalse(calls.contains("deleteMessage"))
    }
    func testAFolderGoesToTheBinWithEverythingInside() async throws {
        shrinkParts()
        serve()
        let api = client()
        let folder = try await api.createFolder(name: "Viaje", parent: "root")
        try await upload(api, Data("una foto".utf8), named: "foto.jpg", parent: folder)
        let listed = try await api.list(parent: "root")
        let target = try XCTUnwrap(listed.first { $0.isFolder })
        try await api.trash(file: target)
        let top = try await api.list(parent: "root")
        XCTAssertTrue(top.isEmpty)
        let inside = try await api.list(parent: folder)
        XCTAssertTrue(inside.isEmpty, "Y lo de dentro también deja de estar")
    }
    func testAFolderCannotBeMovedIntoItself() async throws {
        shrinkParts()
        serve()
        let api = client()
        let outer = try await api.createFolder(name: "Fuera", parent: "root")
        let inner = try await api.createFolder(name: "Dentro", parent: outer)
        let listed = try await api.list(parent: "root")
        let file = try XCTUnwrap(listed.first)
        do {
            try await api.move(file: file, to: inner)
            XCTFail("Un ciclo dejaría la carpeta fuera del árbol y sin manera de volver")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("dentro de sí misma"), error.localizedDescription)
        }
    }
    func testAPrivateChannelSaysItHasNoPublicLinksInsteadOfInventingOne() async throws {
        serve()
        let file = CloudFile(id: "n1", name: "x", mime: "", size: 1, modified: nil, webURL: nil, isFolder: false)
        do {
            _ = try await client().publicLink(for: file)
            XCTFail("No hay enlaces públicos en un canal privado")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("canal privado"), error.localizedDescription)
        }
    }

    // MARK: - Keeping the token to itself

    func testDiagnosticsNeverWriteTheTokenThatTravelsInEveryAddress() throws {
        // Every Bot API address carries the token in its path. A diagnostic that showed it would hand over the
        // channel, so the host is treated like a temporary link: nothing in its path is kept, names or not.
        let url = try XCTUnwrap(TelegramAPI.endpoint(token: token, method: "getFile",
                                                     query: [URLQueryItem(name: "file_id", value: "abc")]))
        let file = try XCTUnwrap(TelegramAPI.contentURL(token: token, path: "documents/file_1.bin"))
        for revealNames in [false, true] {
            let redactor = DiagnosticsRedactor(salt: Data("sal".utf8), revealNames: revealNames)
            for address in [url, file] {
                let shown = redactor.render(address)
                XCTAssertFalse(shown.contains("AAH0abcdefghijklmnop"), shown)
                XCTAssertFalse(shown.contains("123456789"), shown)
            }
        }
        XCTAssertFalse(TelegramAPI.redact("Not Found: /bot\(token)/x", token: token).contains(token))
    }
    func testTheCapabilitiesSayWhatAChannelCanAndCannotDo() {
        let capabilities = Cloud.telegram.capabilities
        XCTAssertEqual(capabilities.signIn, .password)
        XCTAssertTrue(capabilities.isExperimental)
        XCTAssertTrue(capabilities.search, "El árbol está aquí: buscar es gratis")
        XCTAssertTrue(capabilities.copy && capabilities.copiesFolders, "Copiar duplica entradas, no bytes")
        XCTAssertFalse(capabilities.publicLinks, "Un canal privado no tiene direcciones públicas")
        XCTAssertFalse(capabilities.quota)
        XCTAssertFalse(capabilities.permanentDelete, "iCloudy no borra mensajes de un canal")
        XCTAssertEqual(capabilities.sessionLimit, 1, "Un índice fijado y veinte mensajes por minuto: un trabajo a la vez")
    }

    // MARK: - Helpers

    private static func write(_ payload: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: url)
        return url
    }
    private struct MultipartPart {
        let name: String
        let filename: String?
        let payload: Data
    }
    /// Enough of RFC 2388 to read back what iCloudy wrote: the boundary splits the body, each piece carries its
    /// headers before a blank line, and the bytes are whatever is left before the next boundary.
    private static func multipart(_ body: Data, boundary: String) -> [MultipartPart] {
        let marker = Data("--\(boundary)".utf8)
        let blank = Data("\r\n\r\n".utf8)
        var edges: [Range<Data.Index>] = []
        var from = body.startIndex
        while let found = body.range(of: marker, in: from..<body.endIndex) {
            edges.append(found)
            from = found.upperBound
        }
        var pieces: [MultipartPart] = []
        for (position, edge) in edges.enumerated() where position + 1 < edges.count {
            let segment = body[edge.upperBound..<edges[position + 1].lowerBound]
            guard let split = segment.range(of: blank) else { continue }
            let header = String(decoding: segment[segment.startIndex..<split.lowerBound], as: UTF8.self)
            var payload = segment[split.upperBound...]
            // The CRLF that belongs to the boundary, not to the content.
            if payload.count >= 2 { payload = payload.dropLast(2) }
            guard let name = attribute("name", in: header) else { continue }
            pieces.append(MultipartPart(name: name, filename: attribute("filename", in: header), payload: Data(payload)))
        }
        return pieces
    }
    private static func attribute(_ key: String, in header: String) -> String? {
        guard let start = header.range(of: key + "=\"") else { return nil }
        let rest = header[start.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[rest.startIndex..<end])
    }
}
