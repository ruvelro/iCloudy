import Foundation
import Network

/// One FTP control connection and the data connections it opens. Everything runs off the main actor: the protocol is
/// synchronous by nature and a slow server would otherwise freeze the interface.
///
/// Only passive mode is used. Active mode needs the server to connect back, which fails behind almost every router and
/// would make the sandbox's inbound entitlement do real work for no benefit.
actor FTPSession {
    struct Reply {
        let code: Int
        let text: String
        var isPositive: Bool { (200..<400).contains(code) }
    }
    enum Security {
        case none
        /// TLS from the first byte, the FTPS variant that a connection-oriented API can offer. See `docs/FTP.md`.
        case implicitTLS
    }

    let host: String
    let port: UInt16
    let security: Security
    private let user: String
    private let password: String
    private var control: NWConnection?
    private var pending = Data()
    private var receiveEOF: Set<ObjectIdentifier> = []
    /// Set once the server has answered FEAT, so MLSD is only attempted where it exists.
    private var supportsMLSD: Bool?
    /// Seconds any single read, connection or close may take before the operation is abandoned.
    private(set) var timeout: TimeInterval = 45
    func setTimeout(_ seconds: TimeInterval) { timeout = seconds }

    init(host: String, port: UInt16, user: String, password: String, security: Security) {
        self.host = host; self.port = port; self.user = user; self.password = password; self.security = security
    }

    // MARK: - Connection

    private func parameters() -> NWParameters {
        let parameters: NWParameters = security == .implicitTLS ? .tls : .tcp
        parameters.allowLocalEndpointReuse = true
        return parameters
    }
    /// How long a connection may sit in `waiting` before it is given up on. Long enough for a Wi-Fi that is coming
    /// back after a sleep, short enough that a server that is simply not there fails quickly.
    static let pathGrace: TimeInterval = 3
    private func open(port: UInt16) async throws -> NWConnection {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { throw CloudError.message(L("Puerto de servidor no válido.")) }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: parameters())
        defer { connection.stateUpdateHandler = nil }
        try await socketWait(connection, timeout: timeout) { (finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(.success(()))
                case .failed(let error): finish(.failure(Self.describe(error)))
                case .cancelled: finish(.failure(CancellationError()))
                case .waiting(let error):
                    DispatchQueue.global().asyncAfter(deadline: .now() + Self.pathGrace) {
                        if case .waiting = connection.state { finish(.failure(Self.describe(error))) }
                    }
                default: break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
        return connection
    }
    /// Network.framework reports a refused certificate as a bare TLS status, which surfaced as "the operation could
    /// not be completed". A NAS with a certificate of its own is the usual cause, and that is worth saying.
    nonisolated static func describe(_ error: NWError) -> Error {
        guard case .tls(let status) = error else { return error }
        return CloudError.message(L("El servidor rechazó la conexión cifrada (TLS \(status)). Si es un NAS con un certificado propio, macOS no lo acepta: instala ese certificado en el Llavero y márcalo como de confianza, o usa FTP sin cifrar solo dentro de tu red."))
    }
    /// Opens the control connection, greets, authenticates and switches to binary mode.
    func connect() async throws {
        guard control == nil else { return }
        let connection = try await open(port: port)
        control = connection
        pending = Data()
        do { try await handshake() }
        catch { close(); throw error }
    }
    private func handshake() async throws {
        let greeting = try await reply()
        guard greeting.code == 220 else { throw failure(greeting, L("El servidor FTP no aceptó la conexión.")) }
        if security == .implicitTLS {
            // Protect the data channel as well; without this the listings and files travel in the clear.
            _ = try? await send("PBSZ 0")
            let protection = try await send("PROT P")
            guard protection.isPositive else { throw failure(protection, L("El servidor no aceptó cifrar el canal de datos.")) }
        }
        let userReply = try await send("USER \(user)")
        if userReply.code == 331 {
            let passwordReply = try await send("PASS \(password)")
            guard passwordReply.code == 230 else {
                throw CloudError.message(L("El servidor rechazó el usuario o la contraseña."))
            }
        } else if userReply.code != 230 {
            throw failure(userReply, L("El servidor rechazó el usuario o la contraseña."))
        }
        let type = try await send("TYPE I")
        guard type.isPositive else { throw failure(type, L("El servidor no admite transferencias binarias.")) }
        // Older Windows servers answer in the local code page unless told otherwise, which turned accented names into
        // mojibake. Servers that do not know the command answer 500 and carry on, so the reply is not checked.
        _ = try? await send("OPTS UTF8 ON")
    }
    func close() {
        if let control { receiveEOF.remove(ObjectIdentifier(control)); control.cancel() }
        control = nil; pending = Data()
    }
    /// The server closed the control connection, or the socket under it failed. Distinct from a refusal so the
    /// operation can be repeated on a fresh connection, and so the person reads "closed", not "refused".
    struct ConnectionLost: LocalizedError {
        var errorDescription: String? { L("El servidor FTP cerró la conexión.") }
    }
    /// Reconnects once when the server has dropped an idle connection, which FTP servers do aggressively: vsftpd
    /// closes after five minutes, and the next command then fails on a dead socket or reads a 421.
    private func withConnection<T>(_ work: () async throws -> T) async throws -> T {
        try await connect()
        do { return try await work() }
        catch let error where error is NWError || error is ConnectionLost {
            try Task.checkCancellation()
            close()
            try await connect()
            do { return try await work() }
            catch { close(); throw error }
        } catch { close(); throw error }
    }
    /// One operation at a time on the control channel. The actor is reentrant at every `await`, so without this a
    /// listing started by the explorer while the queue was in the middle of a STOR would read the upload's closing
    /// reply as its own, and the upload would read the listing's. Each public operation runs to completion before the
    /// next one starts, in the order they arrived.
    private var lastOperation: Task<Void, Never>?
    private func exclusive<T>(_ work: @escaping () async throws -> T) async throws -> T {
        let previous = lastOperation
        let operation = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        lastOperation = Task { _ = try? await operation.value }
        return try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
    }
    private func failure(_ reply: Reply, _ fallback: String) -> CloudError {
        .message(reply.text.isEmpty ? fallback : fallback + " (" + reply.text + ")")
    }

    // MARK: - Control channel

    /// A callback race, not a task group: cancelling a child task cannot resume a Network continuation.
    private func socketWait<T: Sendable>(_ connection: NWConnection, timeout: TimeInterval,
                               start: (@escaping @Sendable (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let wait = SocketWait<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard wait.install(continuation) else { return }
                wait.arm(timeout: timeout) {
                    connection.cancel()
                }
                start { result in
                    if case .failure = result { connection.cancel() }
                    wait.resolve(result)
                }
            }
        } onCancel: {
            wait.resolve(.failure(CancellationError()))
            connection.cancel()
        }
    }
    private func rawSend(_ connection: NWConnection, _ data: Data) async throws {
        try await socketWait(connection, timeout: timeout) { (finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            })
        }
    }
    /// Sending EOF is bounded and cancellation remains an error, never a successful upload.
    private func finish(_ connection: NWConnection) async throws {
        try await socketWait(connection, timeout: min(timeout, 5)) { (finish: @escaping @Sendable (Result<Void, Error>) -> Void) in
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if let error { finish(.failure(error)) } else { finish(.success(())) }
            })
        }
    }
    private func rawReceive(_ connection: NWConnection) async throws -> Data? {
        let id = ObjectIdentifier(connection)
        guard !receiveEOF.contains(id) else { return nil }
        let packet: (Data?, Bool) = try await socketWait(connection, timeout: timeout) { finish in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let error { finish(.failure(error)) }
                else { finish(.success((data, complete))) }
            }
        }
        // Network can deliver the final bytes and EOF together. Reading again after that raises ENOSTR;
        // treating every error as EOF used to hide this bug, along with timeouts and real network failures.
        if packet.1 { receiveEOF.insert(id) }
        if let data = packet.0, !data.isEmpty { return data }
        return packet.1 ? nil : Data()
    }
    /// Reads one complete reply, joining the continuation lines of a multi-line answer.
    private func reply() async throws -> Reply {
        guard let connection = control else { throw CloudError.message(L("No hay conexión con el servidor FTP.")) }
        let deadline = Date().addingTimeInterval(timeout)
        var lines: [String] = []
        while true {
            while let index = pending.firstIndex(of: 0x0A) {
                let raw = pending[pending.startIndex..<index]
                pending.removeSubrange(pending.startIndex...index)
                let line = String(decoding: raw, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(line)
                // A reply ends with "NNN "; "NNN-" introduces more lines.
                if line.count >= 4, line.prefix(3).allSatisfy(\.isNumber), line[line.index(line.startIndex, offsetBy: 3)] == " " {
                    let code = Int(line.prefix(3)) ?? 0
                    return Reply(code: code, text: lines.joined(separator: " ").trimmingCharacters(in: .whitespaces))
                }
            }
            guard Date() < deadline else { throw CloudError.message(L("El servidor FTP no respondió a tiempo.")) }
            guard let chunk = try await rawReceive(connection) else { close(); throw ConnectionLost() }
            pending.append(chunk)
        }
    }
    /// A command line is terminated by CR LF, so a name that contains either would end the command early and start
    /// another: `informe\rDELE /web/index.html` is two commands. Nothing with a line break is ever sent.
    /// Checked on scalars, not characters: Swift folds "\r\n" into one character, and `contains("\r")` misses it.
    static func isSafeLine(_ line: String) -> Bool { !line.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" } }
    /// Writes one command and reads its reply. Callers hold the lock and have a live connection.
    private func send(_ line: String) async throws -> Reply {
        guard Self.isSafeLine(line) else { throw CloudError.message(L("El nombre contiene un salto de línea, que FTP no admite.")) }
        guard let connection = control else { throw ConnectionLost() }
        do { try await rawSend(connection, Data((line + "\r\n").utf8)) }
        catch let error as NWError { close(); throw error }
        let answer = try await reply()
        // 421 is the server saying goodbye, usually for idleness; the socket is about to close under us.
        if answer.code == 421 { close(); throw ConnectionLost() }
        return answer
    }
    @discardableResult
    func command(_ line: String) async throws -> Reply {
        try await exclusive { try await self.withConnection { try await self.send(line) } }
    }
    /// Same as `command`, but fails when the server answers with an error code.
    @discardableResult
    func require(_ line: String, _ description: String) async throws -> Reply {
        let reply = try await command(line)
        guard reply.isPositive else { throw failure(reply, description) }
        return reply
    }

    // MARK: - Data channel

    /// Asks for a passive data port. EPSV works over IPv6 and is preferred; PASV is the fallback.
    private func passivePort() async throws -> UInt16 {
        let extended = try await send("EPSV")
        if extended.isPositive, let port = Self.parseEPSV(extended.text) { return port }
        let passive = try await send("PASV")
        guard passive.isPositive, let port = Self.parsePASV(passive.text) else {
            throw failure(passive, L("El servidor no aceptó el modo pasivo."))
        }
        return port
    }
    static func parseEPSV(_ text: String) -> UInt16? {
        // 229 Entering Extended Passive Mode (|||51234|)
        guard let open = text.firstIndex(of: "("), let close = text.lastIndex(of: ")") else { return nil }
        let inside = text[text.index(after: open)..<close]
        let parts = inside.split(separator: "|", omittingEmptySubsequences: false)
        return parts.compactMap { UInt16($0) }.last
    }
    static func parsePASV(_ text: String) -> UInt16? {
        // 227 Entering Passive Mode (10,0,0,1,200,21) -> port = 200 * 256 + 21
        guard let open = text.lastIndex(of: "("), let close = text.lastIndex(of: ")"), open < close else { return nil }
        let numbers = text[text.index(after: open)..<close].split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 6, numbers[4] >= 0, numbers[4] <= 255, numbers[5] >= 0, numbers[5] <= 255 else { return nil }
        return UInt16(numbers[4] * 256 + numbers[5])
    }

    /// Runs a command whose payload arrives on a separate connection, e.g. LIST, MLSD or RETR.
    private func receiveData(command line: String, into sink: (Data) throws -> Void) async throws {
        let port = try await passivePort()
        let data = try await open(port: port)
        defer { receiveEOF.remove(ObjectIdentifier(data)); data.cancel() }
        let started = try await send(line)
        // 125 and 150 both mean the transfer is about to start.
        guard [125, 150].contains(started.code) else { throw failure(started, L("El servidor no pudo iniciar la transferencia.")) }
        while true {
            // Most servers end a transfer by closing the data connection, which can surface as EOF or as a reset
            // depending on timing. Either way the control channel's closing reply is what decides success.
            let chunk: Data?
            try Task.checkCancellation()
            do { chunk = try await rawReceive(data) }
            catch NWError.posix(.ECONNRESET) { break }
            guard let chunk else { break }
            if !chunk.isEmpty { try sink(chunk) }
        }
        data.cancel()
        try Task.checkCancellation()
        let finished = try await reply()
        guard finished.isPositive else { throw failure(finished, L("La transferencia no se completó.")) }
    }
    func receiveText(command line: String) async throws -> String {
        var buffer = Data()
        try await receiveData(command: line) { buffer.append($0) }
        return String(decoding: buffer, as: UTF8.self)
    }
    func retrieve(path: String, to destination: URL, maxBytes: Int64? = nil, progress: @Sendable @escaping (Int64) -> Void) async throws {
        try await exclusive { try await self.withConnection { try await self.retrieveUnlocked(path: path, to: destination, maxBytes: maxBytes, progress: progress) } }
    }
    private func retrieveUnlocked(path: String, to destination: URL, maxBytes: Int64? = nil, progress: @Sendable @escaping (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var written: Int64 = 0
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: destination) } }
        try await receiveData(command: "RETR " + path) { chunk in
            try DownloadBudget.check(written + Int64(chunk.count), maximum: maxBytes)
            try handle.write(contentsOf: chunk)
            written += Int64(chunk.count)
            progress(written)
        }
        complete = true
    }
    /// Sends a local file. FTP has no checksum of its own, so the only confirmation is the server's closing reply.
    func store(_ source: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws {
        try await exclusive { try await self.withConnection { try await self.storeUnlocked(source, to: path, progress: progress) } }
    }
    private func storeUnlocked(_ source: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws {
        let sourceStamp = try UploadSourceStamp(source)
        let port = try await passivePort()
        let data = try await open(port: port)
        defer { receiveEOF.remove(ObjectIdentifier(data)); data.cancel() }
        let started = try await send("STOR " + path)
        guard [125, 150].contains(started.code) else { throw failure(started, L("El servidor no pudo iniciar la subida.")) }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while true {
            // Cancelling a transfer must stop the bytes, not just mark the job; without this a 4 GB upload kept
            // going to the end after the person had cancelled it.
            try Task.checkCancellation()
            try sourceStamp.validate(source)
            let chunk = try handle.read(upToCount: 256 * 1024) ?? Data()
            try sourceStamp.validate(source)
            if chunk.isEmpty { break }
            try await rawSend(data, chunk)
            sent += Int64(chunk.count)
            progress(sent)
        }
        // A clean end of file is what tells the server the upload is complete.
        try sourceStamp.validate(source)
        try await finish(data)
        try Task.checkCancellation()
        let finished = try await reply()
        guard finished.isPositive else { throw failure(finished, L("El servidor no confirmó la subida.")) }
    }

    // MARK: - Directory listing

    func list(path: String) async throws -> [CloudFile] {
        try await exclusive { try await self.withConnection { try await self.listUnlocked(path: path) } }
    }
    private func listUnlocked(path: String) async throws -> [CloudFile] {
        if supportsMLSD == nil {
            let features = try await send("FEAT")
            supportsMLSD = features.text.uppercased().contains("MLSD")
        }
        let quoted = path.isEmpty ? "/" : path
        if supportsMLSD == true {
            let text = try await receiveText(command: "MLSD " + quoted)
            return FTPListing.parseMLSD(text, parent: quoted)
        }
        let text = try await receiveText(command: "LIST " + quoted)
        return FTPListing.parseLIST(text, parent: quoted)
    }
}

/// Handles cancellation before registration, timeout, and late callbacks with exactly one resume.
private final class SocketWait<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var timer: DispatchWorkItem?
    func install(_ continuation: CheckedContinuation<T, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); continuation.resume(with: result); return false }
        self.continuation = continuation
        lock.unlock()
        return true
    }
    @discardableResult
    func resolve(_ value: Result<T, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let continuation = self.continuation; self.continuation = nil
        let timer = self.timer; self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(with: value)
        return true
    }
    func arm(timeout: TimeInterval, cancel: @escaping @Sendable () -> Void) {
        let timer = DispatchWorkItem { [weak self] in
            if self?.resolve(.failure(CloudError.message(L("El servidor FTP no respondió a tiempo.")))) == true { cancel() }
        }
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        self.timer = timer
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
    }
}

/// Turns the two listing formats FTP servers actually produce into `CloudFile`s.
enum FTPListing {
    static func join(_ parent: String, _ name: String) -> String {
        parent == "/" || parent.isEmpty ? "/" + name : parent + "/" + name
    }
    /// RFC 3659 machine listing: `type=file;size=12;modify=20260101120000; nombre.txt`
    static func parseMLSD(_ text: String, parent: String) -> [CloudFile] {
        text.split(whereSeparator: \.isNewline).compactMap { line -> CloudFile? in
            let line = String(line)
            // Facts never contain a space, so the first "; " is the boundary with the file name.
            guard let boundary = line.range(of: "; ") else { return nil }
            let name = String(line[boundary.upperBound...])
            guard !name.isEmpty, name != ".", name != ".." else { return nil }
            var facts: [String: String] = [:]
            for fact in line[line.startIndex..<boundary.lowerBound].split(separator: ";") {
                let pair = fact.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { facts[pair[0].lowercased()] = String(pair[1]) }
            }
            let type = facts["type"]?.lowercased() ?? "file"
            guard type != "cdir", type != "pdir" else { return nil }
            let folder = type == "dir"
            return CloudFile(id: join(parent, name), name: name,
                             mime: folder ? "application/vnd.google-apps.folder" : CloudAPI.mime(forName: name),
                             size: folder ? nil : facts["size"].flatMap(Int64.init),
                             modified: facts["modify"].flatMap(timestamp), webURL: nil, isFolder: folder)
        }
    }
    /// `modify` is YYYYMMDDHHMMSS in UTC.
    static func timestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: String(value.prefix(14)))
    }
    /// Human listings: Unix `ls -l` style, and the DOS style some Windows servers still emit.
    static func parseLIST(_ text: String, parent: String) -> [CloudFile] {
        text.split(whereSeparator: \.isNewline).compactMap { raw -> CloudFile? in
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("total ") else { return nil }
            if let first = line.first, "dl-".contains(first) { return unix(line, parent: parent) }
            // A Unix listing also names devices, pipes and sockets, which are not content and cannot be transferred.
            // Sending those down the DOS parser invented entries with nonsense names and sizes.
            if let first = line.first, "bcps".contains(first), line.count > 10,
               line.prefix(10).allSatisfy({ "rwxsStT-dlbcps".contains($0) }) { return nil }
            return dos(line, parent: parent)
        }
    }
    private static func unix(_ line: String, parent: String) -> CloudFile? {
        // drwxr-xr-x  2 user group 4096 Jan  1 12:00 nombre con espacios
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 9 else { return nil }
        // The name starts after the 8th field; rejoining keeps spaces inside it.
        var remainder = Substring(line)
        for _ in 0..<8 {
            guard let space = remainder.firstIndex(of: " ") else { return nil }
            remainder = remainder[remainder.index(after: space)...].drop(while: { $0 == " " })
        }
        let name = String(remainder)
        guard !name.isEmpty, name != ".", name != ".." else { return nil }
        let folder = line.hasPrefix("d")
        // A symbolic link points somewhere iCloudy cannot verify; it is listed but never treated as a folder.
        let clean = line.hasPrefix("l") ? String(name.split(separator: " -> ").first ?? Substring(name)) : name
        return CloudFile(id: join(parent, clean), name: clean,
                         mime: folder ? "application/vnd.google-apps.folder" : CloudAPI.mime(forName: clean),
                         size: folder ? nil : Int64(fields[4]), modified: nil, webURL: nil, isFolder: folder)
    }
    private static func dos(_ line: String, parent: String) -> CloudFile? {
        // 01-01-26  12:00PM       <DIR>          carpeta
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        let folder = fields[2] == "<DIR>"
        var remainder = Substring(line)
        for _ in 0..<3 {
            guard let space = remainder.firstIndex(of: " ") else { return nil }
            remainder = remainder[remainder.index(after: space)...].drop(while: { $0 == " " })
        }
        let name = String(remainder)
        guard !name.isEmpty else { return nil }
        return CloudFile(id: join(parent, name), name: name,
                         mime: folder ? "application/vnd.google-apps.folder" : CloudAPI.mime(forName: name),
                         size: folder ? nil : Int64(fields[2]), modified: nil, webURL: nil, isFolder: folder)
    }
}
