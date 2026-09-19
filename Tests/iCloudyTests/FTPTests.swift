import XCTest
import Network
@testable import iCloudy

/// Resumes a continuation exactly once across the listener's state callbacks.
private final class Ready: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func once(_ body: () -> Void) {
        lock.lock(); let first = !done; done = true; lock.unlock()
        if first { body() }
    }
}

/// A minimal FTP server that speaks just enough of the protocol to exercise the real socket path: greeting,
/// authentication, FEAT, passive mode, MLSD, RETR and STOR. It runs in process, on the loopback interface.
final class FakeFTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-ftp")
    private let lock = NSLock()
    private var control: NWConnection?
    private var buffer = Data()
    private var dataListener: NWListener?
    private var dataConnection: NWConnection?
    private var pendingData: ((NWConnection) -> Void)?
    /// Uploads the server accepted, by path.
    private(set) var stored: [String: Data] = [:]
    private var files: [String: Data]
    private var listings: [String: String]
    private(set) var commands: [String] = []

    init(files: [String: Data], listings: [String: String]) throws {
        self.files = files; self.listings = listings
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let ready = Ready()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: ready.once { continuation.resume() }
                case .failed(let error): ready.once { continuation.resume(throwing: error) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return listener.port?.rawValue ?? 0
    }
    func stop() {
        listener.cancel(); control?.cancel(); dataListener?.cancel(); dataConnection?.cancel()
    }
    func log() -> [String] { lock.withLock { commands } }
    func uploaded() -> [String: Data] { lock.withLock { stored } }
    /// What a server does to an idle client: closes the control connection without a word.
    func dropControl() { control?.cancel(); control = nil; buffer = Data() }

    private func accept(_ connection: NWConnection) {
        control = connection
        connection.start(queue: queue)
        send("220 iCloudy fake FTP\r\n")
        read()
    }
    private func send(_ text: String) {
        control?.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
    private func read() {
        control?.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, _ in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let index = self.buffer.firstIndex(of: 0x0A) {
                let raw = self.buffer[self.buffer.startIndex..<index]
                self.buffer.removeSubrange(self.buffer.startIndex...index)
                self.handle(String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if !complete { self.read() }
        }
    }
    private func handle(_ line: String) {
        lock.withLock { commands.append(line) }
        let verb = line.split(separator: " ").first.map(String.init)?.uppercased() ?? ""
        let argument = line.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
        switch verb {
        case "USER": send("331 Necesita contraseña\r\n")
        case "PASS": send(argument == "secreta" ? "230 Sesión iniciada\r\n" : "530 Credenciales incorrectas\r\n")
        case "TYPE": send("200 Modo binario\r\n")
        case "PWD": send("257 \"/\"\r\n")
        case "FEAT": send("211-Extensiones\r\n MLSD\r\n EPSV\r\n211 Fin\r\n")
        case "EPSV": openDataListener()
        case "MLSD":
            let listing = listings[argument] ?? ""
            startTransfer { connection in
                connection.send(content: Data(listing.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        case "RETR":
            guard let payload = files[argument] else { send("550 No existe\r\n"); return }
            startTransfer { connection in
                connection.send(content: payload, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            }
        case "STOR":
            let path = argument
            startTransfer { [weak self] connection in
                var received = Data()
                func pump() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, _ in
                        if let data { received.append(data) }
                        if complete {
                            self?.lock.withLock { self?.stored[path] = received }
                            self?.send("226 Subida completa\r\n")
                            connection.cancel()
                        } else { pump() }
                    }
                }
                pump()
            }
            return   // the 226 is sent once the upload finishes
        case "MKD": send("257 \"\(argument)\" creada\r\n")
        case "DELE", "RMD": send("250 Eliminado\r\n")
        case "RNFR": send("350 Listo para el nuevo nombre\r\n")
        case "RNTO": send("250 Renombrado\r\n")
        case "QUIT": send("221 Adiós\r\n")
        default: send("502 No implementado\r\n")
        }
    }
    private func openDataListener() {
        dataListener?.cancel()
        // Each passive request gets a fresh channel: reusing the previous one would send data down a closed socket.
        dataConnection?.cancel(); dataConnection = nil; pendingData = nil
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        guard let listener = try? NWListener(using: parameters) else { send("425 Sin canal de datos\r\n"); return }
        dataListener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.dataConnection = connection
            connection.start(queue: self.queue)
            if let action = self.pendingData { self.pendingData = nil; action(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state, let port = listener.port?.rawValue else { return }
            self?.send("229 Modo pasivo extendido (|||\(port)|)\r\n")
        }
        listener.start(queue: queue)
    }
    /// Announces the transfer, then runs `action` as soon as the client opens the data connection.
    private func startTransfer(_ action: @escaping (NWConnection) -> Void) {
        send("150 Abriendo el canal de datos\r\n")
        if let connection = dataConnection, dataListener != nil {
            action(connection)
        } else {
            pendingData = action
        }
        // Downloads and listings finish as soon as the data connection closes.
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.pendingData == nil else { return }
            self.send("226 Transferencia completa\r\n")
        }
    }
}

@MainActor
final class FTPTests: XCTestCase {

    // MARK: - Parsing

    func testPassiveRepliesAreParsedInBothForms() {
        XCTAssertEqual(FTPSession.parseEPSV("229 Entering Extended Passive Mode (|||51234|)"), 51234)
        XCTAssertNil(FTPSession.parseEPSV("229 sin paréntesis"))
        XCTAssertEqual(FTPSession.parsePASV("227 Entering Passive Mode (10,0,0,1,200,21)"), 200 * 256 + 21)
        XCTAssertEqual(FTPSession.parsePASV("227 Passive (127,0,0,1,0,21)"), 21)
        XCTAssertNil(FTPSession.parsePASV("227 Entering Passive Mode (10,0,0,1,300,21)"), "Un octeto fuera de rango no es un puerto")
        XCTAssertNil(FTPSession.parsePASV("227 sin números"))
    }

    func testMLSDListingKeepsTypesSizesAndDatesAndDropsTheDirectoryItself() {
        let text = """
        type=cdir;modify=20260101120000; /fotos
        type=pdir;modify=20260101120000; ..
        type=dir;modify=20260102130000; Viaje de verano
        type=file;size=2048;modify=20260103140500; informe final.pdf
        basura sin formato
        """
        let files = FTPListing.parseMLSD(text, parent: "/fotos")
        XCTAssertEqual(files.map(\.name), ["Viaje de verano", "informe final.pdf"], "cdir y pdir no son contenido")
        XCTAssertTrue(files[0].isFolder)
        XCTAssertNil(files[0].size, "Una carpeta no declara tamaño")
        XCTAssertEqual(files[1].size, 2048)
        XCTAssertEqual(files[1].id, "/fotos/informe final.pdf", "El identificador es la ruta completa")
        XCTAssertEqual(files[1].mime, "application/pdf")
        var components = DateComponents()
        components.year = 2026; components.month = 1; components.day = 3
        components.hour = 14; components.minute = 5; components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        XCTAssertEqual(files[1].modified, Calendar(identifier: .gregorian).date(from: components), "modify viene en UTC")
    }

    func testUnixAndDOSListingsAreUnderstood() {
        let unix = """
        total 12
        drwxr-xr-x   2 ana  staff   4096 Jan  1 12:00 Mi carpeta
        -rw-r--r--   1 ana  staff   1234 Jan  1 12:00 nota con espacios.txt
        lrwxrwxrwx   1 ana  staff      7 Jan  1 12:00 enlace -> destino
        """
        let files = FTPListing.parseLIST(unix, parent: "/base")
        XCTAssertEqual(files.map(\.name), ["Mi carpeta", "nota con espacios.txt", "enlace"])
        XCTAssertTrue(files[0].isFolder)
        XCTAssertEqual(files[1].size, 1234)
        XCTAssertFalse(files[2].isFolder, "Un enlace simbólico no se trata como carpeta")
        XCTAssertEqual(files[1].id, "/base/nota con espacios.txt")

        let dos = """
        01-01-26  12:00PM       <DIR>          Carpeta
        01-01-26  12:00PM                 1234 archivo.txt
        """
        let windows = FTPListing.parseLIST(dos, parent: "/")
        XCTAssertEqual(windows.map(\.name), ["Carpeta", "archivo.txt"])
        XCTAssertTrue(windows[0].isFolder)
        XCTAssertEqual(windows[1].size, 1234)
        XCTAssertEqual(windows[1].id, "/archivo.txt")
    }

    func testEndpointParsingChoosesSchemePortAndBase() throws {
        let plain = try CloudAPI.ftpEndpoint("ftp://servidor.example.com/carpeta/")
        XCTAssertEqual(plain.host, "servidor.example.com")
        XCTAssertEqual(plain.port, 21)
        XCTAssertEqual(plain.base, "/carpeta")
        if case .none = plain.security {} else { XCTFail("ftp:// no debe cifrarse") }

        let secure = try CloudAPI.ftpEndpoint("ftps://nas.local")
        XCTAssertEqual(secure.port, 990, "FTPS implícito usa el 990 por omisión")
        XCTAssertEqual(secure.base, "/")
        if case .implicitTLS = secure.security {} else { XCTFail("ftps:// debe cifrarse") }

        XCTAssertEqual(try CloudAPI.ftpEndpoint("ftp://nas.local:2121/x").port, 2121)
        XCTAssertThrowsError(try CloudAPI.ftpEndpoint("no es una dirección"))
    }

    func testCapabilitiesHideWhatFTPCannotDo() {
        let ftp = Cloud.ftp.capabilities
        XCTAssertFalse(ftp.oauth)
        XCTAssertFalse(ftp.search)
        XCTAssertFalse(ftp.publicLinks)
        XCTAssertFalse(ftp.copy, "FTP no copia en el servidor")
        XCTAssertFalse(ftp.quota)
        XCTAssertFalse(ftp.reversibleTrash, "DELE es definitivo")
        XCTAssertFalse(ftp.checksum)
        XCTAssertTrue(ftp.move, "RNFR/RNTO sí mueve")
        XCTAssertTrue(Cloud.ftp.isSelfHosted)
        XCTAssertTrue(Cloud.webdav.isSelfHosted)
        XCTAssertFalse(Cloud.google.isSelfHosted)
    }

    // MARK: - Real socket round trip

    private func account(port: UInt16) -> Account {
        Account(id: "ftp:test", cloud: .ftp, name: "Test", email: "ana@test", clientID: "", clientSecret: nil,
                serverURL: "ftp://127.0.0.1:\(port)/")
    }
    private func client(port: UInt16) -> CloudAPI {
        CloudAPI(account: account(port: port), tokenProvider: { Data("ana:secreta".utf8).base64EncodedString() })
    }
    /// Keeps a broken expectation from stalling the suite for the full production timeout.
    private func hurry(_ api: CloudAPI) async throws { await (try await api.ftp()).setTimeout(6) }

    func testListsDownloadsAndUploadsAgainstARealServer() async throws {
        let payload = Data(repeating: 65, count: 5000)
        let listing = "type=dir;modify=20260101120000; Documentos\r\ntype=file;size=5000;modify=20260101120000; datos.bin\r\n"
        let server = try FakeFTPServer(files: ["/datos.bin": payload], listings: ["/": listing])
        let port = try await server.start()
        defer { server.stop() }
        let api = client(port: port)
        try await hurry(api)

        let files = try await api.list(parent: "root")
        XCTAssertEqual(files.map(\.name), ["Documentos", "datos.bin"], "Carpetas primero")
        XCTAssertEqual(files[1].size, 5000)
        XCTAssertTrue(server.log().contains("USER ana"), "Se autentica antes de listar")
        XCTAssertTrue(server.log().contains("TYPE I"), "Las transferencias son binarias")
        XCTAssertTrue(server.log().contains("MLSD /"), "Se prefiere MLSD cuando FEAT lo anuncia")

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        try await api.download(file: files[1], to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload, "El archivo llega entero")

        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("contenido subido".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var checkpoint = UploadCheckpoint(total: 16, modified: try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let receipt = try await api.resumableUpload(local: source, parent: "root", name: "subido.txt", replacing: nil,
                                                    checkpoint: checkpoint, save: { checkpoint = $0 }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "/subido.txt")
        XCTAssertEqual(receipt.verification, .unavailable, "FTP no informa de ninguna suma de verificación")
        XCTAssertEqual(server.uploaded()["/subido.txt"], Data("contenido subido".utf8), "Órdenes recibidas: \(server.log())")
        XCTAssertTrue(checkpoint.complete)
    }

    func testADroppedControlConnectionIsReopenedOnTheNextOperation() async throws {
        // FTP servers close an idle control connection after a few minutes. Before, the next command went down the
        // dead socket and every listing of that account failed until it was disconnected and connected again.
        let listing = "type=file;size=3;modify=20260101120000; a.txt\r\n"
        let server = try FakeFTPServer(files: [:], listings: ["/": listing])
        let port = try await server.start()
        defer { server.stop() }
        let api = client(port: port)
        try await hurry(api)
        let before = try await api.list(parent: "root")
        XCTAssertEqual(before.map(\.name), ["a.txt"])
        server.dropControl()
        try await Task.sleep(for: .milliseconds(200))
        let after = try await api.list(parent: "root")
        XCTAssertEqual(after.map(\.name), ["a.txt"], "Se vuelve a conectar sola")
        XCTAssertEqual(server.log().filter { $0 == "USER ana" }.count, 2, "Hubo una segunda sesión: \(server.log())")
    }

    func testOperationsOnTheSameSessionRunOneAtATime() async throws {
        // The explorer and the queue share one control connection. Two operations interleaved on it read each
        // other's replies; here a listing, an upload and another listing are started at once and must all succeed.
        let listing = "type=file;size=3;modify=20260101120000; a.txt\r\n"
        let server = try FakeFTPServer(files: [:], listings: ["/": listing])
        let port = try await server.start()
        defer { server.stop() }
        let api = client(port: port)
        try await hurry(api)
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("contenido".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let stamp = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        async let first = api.list(parent: "root")
        async let upload = api.resumableUpload(local: source, parent: "root", name: "s.txt", replacing: nil,
                                               checkpoint: UploadCheckpoint(total: 9, modified: stamp), save: { _ in }, progress: { _, _ in })
        async let second = api.list(parent: "root")
        let (a, receipt, b) = try await (first, upload, second)
        XCTAssertEqual(a.map(\.name), ["a.txt"])
        XCTAssertEqual(b.map(\.name), ["a.txt"])
        XCTAssertEqual(receipt.remoteID, "/s.txt")
        XCTAssertEqual(server.uploaded()["/s.txt"], Data("contenido".utf8), "Órdenes: \(server.log())")
        // Every data transfer opens its own passive channel, and they must not overlap: a STOR between two MLSDs.
        let transfers = server.log().filter { $0.hasPrefix("MLSD") || $0.hasPrefix("STOR") }
        XCTAssertEqual(transfers.count, 3, "\(server.log())")
    }

    func testALineBreakInANameNeverReachesTheServer() async throws {
        // A command ends at CR LF, so "informe\rDELE /index.html" would be two commands. It is refused before the
        // socket, and the name rules refuse it before the transfer even starts.
        XCTAssertNotNil(FileNames.problem(with: "informe\rDELE /index.html", for: .ftp))
        XCTAssertNotNil(FileNames.problem(with: "dos\nlíneas.txt", for: .ftp))
        XCTAssertNotNil(FileNames.problem(with: "a\r\nb", for: .ftp), "CR LF is one Swift character; it must still be caught")
        XCTAssertNil(FileNames.problem(with: "informe final.pdf", for: .ftp))
        XCTAssertFalse(FTPSession.isSafeLine("STOR a\r\nDELE b"))
        XCTAssertTrue(FTPSession.isSafeLine("STOR a b"))
        let server = try FakeFTPServer(files: [:], listings: ["/": ""])
        let port = try await server.start()
        defer { server.stop() }
        let api = client(port: port)
        try await hurry(api)
        let session = try await api.ftp()
        do { _ = try await session.command("STOR a\r\nDELE /b"); XCTFail("Debe rechazarse") }
        catch { XCTAssertTrue(error.localizedDescription.contains("salto de línea"), error.localizedDescription) }
        XCTAssertFalse(server.log().contains { $0.hasPrefix("DELE") }, server.log().description)
    }

    func testCredentialsTypedIntoTheAddressAreStrippedFromWhatIsStored() async throws {
        let server = try FakeFTPServer(files: [:], listings: ["/": ""])
        let port = try await server.start()
        defer { server.stop() }
        let oauth = OAuth { _ in XCTFail("FTP must not open a browser"); return false }
        let (account, credential) = try await oauth.signInFTP(server: "ftp://ana:secreta@127.0.0.1:\(port)/", username: "", password: "")
        XCTAssertEqual(account.serverURL, "ftp://127.0.0.1:\(port)/", "La contraseña no acaba en accounts.json")
        XCTAssertFalse(account.id.contains("secreta"))
        XCTAssertEqual(credential.accessToken, Data("ana:secreta".utf8).base64EncodedString(), "Pero sí se usa para entrar")
        XCTAssertTrue(server.log().contains("PASS secreta"))
    }

    func testWrongPasswordIsReportedWithoutStoringAnything() async throws {
        let server = try FakeFTPServer(files: [:], listings: ["/": ""])
        let port = try await server.start()
        defer { server.stop() }
        let api = CloudAPI(account: account(port: port), tokenProvider: { Data("ana:mala".utf8).base64EncodedString() })
        do {
            _ = try await api.list(parent: "root")
            XCTFail("Una contraseña incorrecta debe fallar")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("usuario o la contraseña"), error.localizedDescription)
        }
    }
}
