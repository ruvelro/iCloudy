import Foundation

/// SFTP version 3, the one every server speaks, over the channel `SSHTransport` opens. Requests carry an id and
/// answers can come back in any order, which is what lets reads and writes be pipelined instead of waiting a round
/// trip per block: with the 16 requests kept in flight here a download runs at the link's speed rather than at the
/// latency's.
actor SFTPClient {
    private let transport: SSHTransport
    private var nextID: UInt32 = 0
    private var started = false
    /// Extensions the server announced with its version; `posix-rename@openssh.com` and `statvfs@openssh.com` matter.
    private(set) var extensions: [String: String] = [:]
    /// Answers that arrived while another request was being waited for.
    private var parked: [UInt32: (type: UInt8, body: Data)] = [:]

    init(transport: SSHTransport) { self.transport = transport }
    var hostKey: Data? { get async { await transport.hostKey } }

    enum Packet {
        static let initialize: UInt8 = 1, version: UInt8 = 2, open: UInt8 = 3, close: UInt8 = 4, read: UInt8 = 5, write: UInt8 = 6
        static let lstat: UInt8 = 7, fstat: UInt8 = 8, setstat: UInt8 = 9, opendir: UInt8 = 11, readdir: UInt8 = 12
        static let remove: UInt8 = 13, mkdir: UInt8 = 14, rmdir: UInt8 = 15, realpath: UInt8 = 16, stat: UInt8 = 17, rename: UInt8 = 18
        static let status: UInt8 = 101, handle: UInt8 = 102, data: UInt8 = 103, name: UInt8 = 104, attrs: UInt8 = 105
        static let extended: UInt8 = 200, extendedReply: UInt8 = 201
    }
    struct Attributes {
        var size: UInt64?
        var permissions: UInt32?
        var modified: Date?
        var isDirectory: Bool { permissions.map { $0 & 0o170000 == 0o040000 } ?? false }
        var isSymbolicLink: Bool { permissions.map { $0 & 0o170000 == 0o120000 } ?? false }
        init(size: UInt64? = nil, permissions: UInt32? = nil, modified: Date? = nil) {
            self.size = size; self.permissions = permissions; self.modified = modified
        }
        init(reading reader: inout SSHReader) throws {
            let flags = try reader.uint32()
            if flags & 0x1 != 0 { size = try reader.uint64() }
            if flags & 0x2 != 0 { _ = try reader.uint32(); _ = try reader.uint32() }
            if flags & 0x4 != 0 { permissions = try reader.uint32() }
            if flags & 0x8 != 0 { _ = try reader.uint32(); modified = Date(timeIntervalSince1970: TimeInterval(try reader.uint32())) }
            if flags & 0x8000_0000 != 0 {
                for _ in 0..<(try reader.uint32()) { _ = try reader.string(); _ = try reader.string() }
            }
        }
    }
    struct Entry { let name: String; let attributes: Attributes }

    /// What the server said no to, in its own words when it gave any, and in ours otherwise.
    struct Refusal: LocalizedError {
        let code: UInt32
        let message: String
        var errorDescription: String? {
            switch code {
            case 1: return L("Fin del archivo.")
            case 2: return L("El servidor SFTP no encuentra ese elemento.") + detail
            case 3: return L("El servidor SFTP no da permiso para esa operación.") + detail
            case 8: return L("El servidor SFTP no admite esa operación.") + detail
            default: return message.isEmpty ? L("El servidor SFTP rechazó la operación (código \(code)).") : L("El servidor SFTP rechazó la operación: ") + message
            }
        }
        private var detail: String { message.isEmpty ? "" : " (" + message + ")" }
        var isNotFound: Bool { code == 2 }
        var isEOF: Bool { code == 1 }
    }

    // MARK: - Session

    func start() async throws {
        guard !started else { return }
        try await transport.connect()
        var writer = SSHWriter()
        writer.byte(Packet.initialize); writer.uint32(3)
        try await sendRaw(writer.data)
        var (type, reader) = try await receiveRaw()
        guard type == Packet.version else { throw CloudError.message(L("El servidor SFTP no respondió a la negociación de versión.")) }
        let version = try reader.uint32()
        guard version >= 3 else { throw CloudError.message(L("El servidor habla SFTP versión \(version); iCloudy necesita la 3 o superior.")) }
        while !reader.isAtEnd { extensions[try reader.text()] = try reader.text() }
        started = true
    }
    func close() async {
        await transport.close()
        started = false; parked.removeAll()
    }
    /// One request at a time from the outside, in arrival order, the same rule `FTPSession` follows: the actor is
    /// reentrant at every `await`, and two listings sharing the channel would read each other's answers.
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
    /// Reconnects once when the connection went away between operations; a failure inside an operation drops the
    /// session, because answers may still be in flight for requests nobody is waiting for any more.
    private func withSession<T>(_ work: () async throws -> T) async throws -> T {
        try await start()
        do { return try await work() }
        catch let error as Refusal { throw error }
        catch is CancellationError { await close(); throw CancellationError() }
        catch {
            await close()
            throw error
        }
    }

    // MARK: - Framing

    private func sendRaw(_ body: Data) async throws {
        var writer = SSHWriter()
        writer.uint32(UInt32(body.count)); writer.raw(body)
        try await transport.write(writer.data)
    }
    private func receiveRaw() async throws -> (UInt8, SSHReader) {
        var head = SSHReader(try await transport.read(atLeast: 4))
        let length = Int(try head.uint32())
        guard length >= 1, length <= 1 << 26 else { throw SSHReader.Malformed() }
        var reader = SSHReader(try await transport.read(atLeast: length))
        return (try reader.byte(), reader)
    }
    /// Sends one request and returns its id.
    private func request(_ type: UInt8, _ fill: (inout SSHWriter) -> Void) async throws -> UInt32 {
        nextID &+= 1
        let id = nextID
        var writer = SSHWriter()
        writer.byte(type); writer.uint32(id)
        fill(&writer)
        try await sendRaw(writer.data)
        return id
    }
    /// The answer to `id`, parking anything that arrives for another request in the meantime.
    private func response(_ id: UInt32) async throws -> (type: UInt8, reader: SSHReader) {
        if let parked = parked.removeValue(forKey: id) { return (parked.type, SSHReader(parked.body)) }
        while true {
            try Task.checkCancellation()
            var (type, reader) = try await receiveRaw()
            let arrived = try reader.uint32()
            if arrived == id { return (type, reader) }
            parked[arrived] = (type, reader.rest())
            // A pathological server could answer with ids nobody asked for; the parking lot must not grow forever.
            guard parked.count < 4096 else { throw SSHReader.Malformed() }
        }
    }
    /// Reads a STATUS answer and throws unless it is OK.
    private func status(_ id: UInt32) async throws {
        var answer = try await response(id)
        guard answer.type == Packet.status else { throw SSHReader.Malformed() }
        let code = try answer.reader.uint32()
        let message = (try? answer.reader.text()) ?? ""
        guard code == 0 else { throw Refusal(code: code, message: message) }
    }
    private func handle(_ id: UInt32) async throws -> Data {
        var answer = try await response(id)
        if answer.type == Packet.handle { return try answer.reader.string() }
        guard answer.type == Packet.status else { throw SSHReader.Malformed() }
        throw Refusal(code: try answer.reader.uint32(), message: (try? answer.reader.text()) ?? "")
    }
    private func closeHandle(_ handle: Data) async throws {
        try await status(try await request(Packet.close) { $0.string(handle) })
    }

    // MARK: - Paths and listings

    func realpath(_ path: String) async throws -> String {
        try await exclusive { try await self.withSession {
            var answer = try await self.response(try await self.request(Packet.realpath) { $0.string(path) })
            guard answer.type == Packet.name, try answer.reader.uint32() >= 1 else { throw CloudError.message(L("El servidor SFTP no resolvió la ruta «\(path)».")) }
            return try answer.reader.text()
        } }
    }
    func stat(_ path: String) async throws -> Attributes {
        try await exclusive { try await self.withSession {
            var answer = try await self.response(try await self.request(Packet.stat) { $0.string(path) })
            if answer.type == Packet.attrs { return try Attributes(reading: &answer.reader) }
            guard answer.type == Packet.status else { throw SSHReader.Malformed() }
            throw Refusal(code: try answer.reader.uint32(), message: (try? answer.reader.text()) ?? "")
        } }
    }
    func list(_ path: String) async throws -> [Entry] {
        try await exclusive { try await self.withSession {
            let handle = try await self.handle(try await self.request(Packet.opendir) { $0.string(path) })
            var entries: [Entry] = []
            do { try await self.readEntries(handle, into: &entries) }
            catch {
                // The handle is closed before the error goes up; whether that close succeeds no longer matters.
                try? await self.closeHandle(handle)
                throw error
            }
            try await self.closeHandle(handle)
            return entries
        } }
    }
    private func readEntries(_ handle: Data, into entries: inout [Entry]) async throws {
            while true {
                try Task.checkCancellation()
                var answer = try await self.response(try await self.request(Packet.readdir) { $0.string(handle) })
                if answer.type == Packet.status {
                    let code = try answer.reader.uint32()
                    if code == 1 { break }
                    throw Refusal(code: code, message: (try? answer.reader.text()) ?? "")
                }
                guard answer.type == Packet.name else { throw SSHReader.Malformed() }
                for _ in 0..<(try answer.reader.uint32()) {
                    let name = try answer.reader.text()
                    _ = try answer.reader.string()
                    let attributes = try Attributes(reading: &answer.reader)
                    if name != ".", name != ".." { entries.append(Entry(name: name, attributes: attributes)) }
                }
            }
    }
    func mkdir(_ path: String) async throws {
        try await exclusive { try await self.withSession {
            try await self.status(try await self.request(Packet.mkdir) { $0.string(path); $0.uint32(0) })
        } }
    }
    func remove(_ path: String) async throws {
        try await exclusive { try await self.withSession { try await self.status(try await self.request(Packet.remove) { $0.string(path) }) } }
    }
    func rmdir(_ path: String) async throws {
        try await exclusive { try await self.withSession { try await self.status(try await self.request(Packet.rmdir) { $0.string(path) }) } }
    }
    /// The plain RENAME of version 3 refuses to replace an existing target; OpenSSH's extension behaves like rename(2).
    /// Both are refused for a target that exists on the servers that matter, which is what the callers check first.
    func rename(_ from: String, to: String) async throws {
        try await exclusive { try await self.withSession {
            if self.extensions["posix-rename@openssh.com"] != nil {
                try await self.status(try await self.request(Packet.extended) { $0.string("posix-rename@openssh.com"); $0.string(from); $0.string(to) })
            } else {
                try await self.status(try await self.request(Packet.rename) { $0.string(from); $0.string(to) })
            }
        } }
    }
    /// Free and total bytes of the file system under `path`, when the server implements OpenSSH's extension.
    func statvfs(_ path: String) async throws -> (total: Int64, free: Int64)? {
        try await exclusive { try await self.withSession {
            guard self.extensions["statvfs@openssh.com"] != nil else { return nil }
            var answer = try await self.response(try await self.request(Packet.extended) { $0.string("statvfs@openssh.com"); $0.string(path) })
            guard answer.type == Packet.extendedReply else { return nil }
            _ = try answer.reader.uint64()                      // f_bsize
            let fragment = try answer.reader.uint64()           // f_frsize
            let blocks = try answer.reader.uint64()             // f_blocks
            _ = try answer.reader.uint64()                      // f_bfree
            let available = try answer.reader.uint64()          // f_bavail
            guard fragment > 0, blocks > 0 else { return nil }
            return (Int64(clamping: blocks * fragment), Int64(clamping: available * fragment))
        } }
    }

    // MARK: - Transfers

    static let blockSize = 32 * 1024
    static let inFlight = 16

    /// Downloads with `inFlight` reads outstanding; the answers are consumed in the order they were asked for, so
    /// the file is written front to back whatever order the server chose.
    func download(_ path: String, to destination: URL, maxBytes: Int64?, progress: @Sendable @escaping (Int64) -> Void) async throws {
        try await exclusive { try await self.withSession {
            let handle = try await self.handle(try await self.request(Packet.open) { $0.string(path); $0.uint32(1); $0.uint32(0) })
            do { try await self.readFile(handle, to: destination, maxBytes: maxBytes, progress: progress) }
            catch { try? await self.closeHandle(handle); throw error }
            try await self.closeHandle(handle)
        } }
    }
    private func readFile(_ handle: Data, to destination: URL, maxBytes: Int64?, progress: @Sendable @escaping (Int64) -> Void) async throws {
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let file = try FileHandle(forWritingTo: destination)
            var complete = false
            defer {
                try? file.close()
                if !complete { try? FileManager.default.removeItem(at: destination) }
            }
            var written: Int64 = 0
            var offset: UInt64 = 0
            var outstanding: [UInt32] = []
            var finished = false
            func ask() async throws {
                let id = try await self.request(Packet.read) { $0.string(handle); $0.uint64(offset); $0.uint32(UInt32(Self.blockSize)) }
                outstanding.append(id); offset += UInt64(Self.blockSize)
            }
            for _ in 0..<Self.inFlight { try await ask() }
            while !outstanding.isEmpty {
                try Task.checkCancellation()
                var answer = try await self.response(outstanding.removeFirst())
                if answer.type == Packet.status {
                    let code = try answer.reader.uint32()
                    guard code == 1 else { throw Refusal(code: code, message: (try? answer.reader.text()) ?? "") }
                    finished = true
                    continue
                }
                guard answer.type == Packet.data else { throw SSHReader.Malformed() }
                let chunk = try answer.reader.string()
                if chunk.isEmpty { finished = true; continue }
                try DownloadBudget.check(written + Int64(chunk.count), maximum: maxBytes)
                try await TransferThrottle.download(chunk.count)
                try file.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(written)
                // A short read that is not the end means the server gave less than asked; the next request already
                // points past it, so the gap is fetched again from where this one stopped.
                if chunk.count < Self.blockSize, !finished {
                    offset = UInt64(written)
                    for id in outstanding { _ = try? await self.response(id) }
                    outstanding.removeAll()
                }
                if !finished { try await ask() }
            }
            complete = true
    }
    /// Uploads with `inFlight` writes outstanding. The file is created or truncated first; a retry starts over.
    func upload(_ source: URL, to path: String, progress: @Sendable @escaping (Int64) -> Void) async throws {
        try await exclusive { try await self.withSession {
            let stamp = try UploadSourceStamp(source)
            // CREAT | TRUNC | WRITE
            let handle = try await self.handle(try await self.request(Packet.open) { $0.string(path); $0.uint32(0x2 | 0x8 | 0x10); $0.uint32(0) })
            do { try await self.writeFile(handle, from: source, stamp: stamp, progress: progress) }
            catch { try? await self.closeHandle(handle); throw error }
            try await self.closeHandle(handle)
        } }
    }
    private func writeFile(_ handle: Data, from source: URL, stamp: UploadSourceStamp, progress: @Sendable @escaping (Int64) -> Void) async throws {
            let file = try FileHandle(forReadingFrom: source)
            defer { try? file.close() }
            var offset: UInt64 = 0
            var outstanding: [UInt32] = []
            while true {
                try Task.checkCancellation()
                try stamp.validate(source)
                let chunk = try file.read(upToCount: Self.blockSize) ?? Data()
                if chunk.isEmpty { break }
                try await TransferThrottle.upload(chunk.count)
                let at = offset
                outstanding.append(try await self.request(Packet.write) { $0.string(handle); $0.uint64(at); $0.string(chunk) })
                offset += UInt64(chunk.count)
                if outstanding.count >= Self.inFlight {
                    try await self.status(outstanding.removeFirst())
                    progress(Int64(offset) - Int64(outstanding.count * Self.blockSize))
                }
            }
            for id in outstanding { try await self.status(id) }
            try stamp.validate(source)
            progress(Int64(offset))
    }
}
