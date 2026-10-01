import Foundation

/// The diagnostic record of every provider: a ring of recent events in memory and a rotating file beside the app's
/// other data, so a problem can be explained after the fact without anybody having had to switch anything on.
///
/// It generalises what O2's own record proved worth having. Nothing is redacted on the caller's thread and nothing
/// is written there either: `record` only checks the level and hands the raw values to a serial queue, which redacts
/// them, keeps them and writes them to disk in batches. A slow disk never reaches the main actor.
final class DiagnosticsLog: @unchecked Sendable {
    struct Limits: Sendable {
        /// Events kept in memory for the settings window.
        var memory = 2000
        /// Size at which the current file is rotated, and how many files exist at most, the current one included.
        var fileBytes = 512 * 1024
        var files = 3
        /// Files older than this are deleted, and events older than this are left out of an export.
        var maxAge: TimeInterval = 7 * 24 * 3600
        /// Events gathered before a write, and the longest an event waits for one.
        var batch = 100
        var flushDelay: TimeInterval = 2
    }

    /// Where the files live, or nil to keep everything in memory.
    let directory: URL?
    let limits: Limits
    let salt: Data
    private let lock = NSLock()
    private var currentLevel: DiagnosticsLevel
    private let work = DispatchQueue(label: "icloudy.diagnostics", qos: .utility)
    // Everything below belongs to `work`.
    private var ring: [DiagnosticEvent?]
    private var start = 0
    private var count = 0
    private var nextID: UInt64 = 1
    private var pending: [DiagnosticEvent] = []
    private var flushScheduled = false
    private var termination: NSObjectProtocol?

    init(directory: URL?, level: DiagnosticsLevel = .normal, salt: Data? = nil, limits: Limits = Limits()) {
        self.directory = directory
        self.limits = limits
        self.currentLevel = level
        self.salt = salt ?? Self.randomSalt()
        self.ring = Array(repeating: nil, count: max(1, limits.memory))
        // Queued first, so whatever is recorded afterwards lands after the events of earlier runs.
        work.async { [self] in loadPrevious() }
        if directory != nil {
            termination = NotificationCenter.default.addObserver(forName: Notification.Name("NSApplicationWillTerminateNotification"),
                                                                 object: nil, queue: nil) { [weak self] _ in self?.flush() }
        }
    }
    deinit { if let termination { NotificationCenter.default.removeObserver(termination) } }

    var level: DiagnosticsLevel {
        get { lock.withLock { currentLevel } }
        set { lock.withLock { currentLevel = newValue } }
    }
    var redactor: DiagnosticsRedactor { DiagnosticsRedactor(salt: salt, revealNames: level.revealsNames) }

    static func randomSalt() -> Data { Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }) }

    // MARK: - Recording

    /// Cheap for the caller whatever the level: one lock to read the level, and the rest on the log's own queue.
    func record(_ record: DiagnosticRecord) {
        let level = self.level
        guard level.records(record.severity) else { return }
        let redactor = DiagnosticsRedactor(salt: salt, revealNames: level.revealsNames)
        let time = Date()
        work.async { [self] in
            var event = Self.event(from: record, at: time, redactor: redactor)
            event.id = nextID; nextID += 1
            append(event)
            guard directory != nil else { return }
            pending.append(event)
            if pending.count >= limits.batch { writePending() }
            else if !flushScheduled {
                flushScheduled = true
                work.asyncAfter(deadline: .now() + limits.flushDelay) { [self] in writePending() }
            }
        }
    }

    /// Builds the event that is kept. This is the only path from a raw record to anything stored.
    static func event(from record: DiagnosticRecord, at time: Date, redactor: DiagnosticsRedactor) -> DiagnosticEvent {
        var event = DiagnosticEvent(time: time, severity: record.severity, stage: record.stage)
        event.provider = record.provider
        event.account = record.account.map(redactor.account)
        event.transfer = record.transfer.map { String($0.uuidString.prefix(8)).lowercased() }
        event.method = record.method?.uppercased()
        if let url = record.url {
            let (host, path) = redactor.url(url)
            event.host = host; event.path = path
        }
        event.status = record.status
        event.durationMs = record.duration.map { Int(($0 * 1000).rounded()) }
        event.bytesSent = record.bytesSent
        event.bytesReceived = record.bytesReceived
        event.attempt = record.attempt
        event.errorDomain = record.errorDomain
        event.errorCode = record.errorCode.map { String(redactor.text($0).prefix(120)) }
        let parts = [record.command.map(redactor.command), record.message.map(redactor.text)].compactMap { $0 }
        if !parts.isEmpty { event.message = String(parts.joined(separator: " · ").prefix(600)) }
        return event
    }

    /// The same treatment again, at the level in force now. An export goes through it, so an event written while the
    /// detailed level was on loses its names once the level is back to normal.
    static func scrub(_ event: DiagnosticEvent, redactor: DiagnosticsRedactor) -> DiagnosticEvent {
        var clean = event
        if let path = event.path {
            let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
            clean.path = redactor.template(path: parts.first ?? "/", query: parts.count > 1 ? parts[1] : nil, host: event.host)
        }
        clean.message = event.message.map(redactor.text)
        clean.errorCode = event.errorCode.map(redactor.text)
        return clean
    }

    // MARK: - Reading

    /// Recent events, oldest first.
    func events() -> [DiagnosticEvent] { work.sync { orderedRing() } }

    /// Every event still on disk and within the age limit, oldest first, followed by any not written yet.
    func storedEvents() -> [DiagnosticEvent] {
        work.sync {
            guard directory != nil else { return orderedRing() }
            writePending()
            let oldest = Date().addingTimeInterval(-limits.maxAge)
            return fileURLs().reversed().flatMap(Self.decode).filter { $0.time >= oldest }
        }
    }

    /// Writes what is waiting now instead of at the next batch.
    func flush() { work.sync { writePending() } }

    /// Forgets everything: memory, the files and anything still waiting to be written.
    func clear() {
        work.sync {
            ring = Array(repeating: nil, count: ring.count); start = 0; count = 0
            pending.removeAll()
            for file in fileURLs() { try? FileManager.default.removeItem(at: file) }
        }
    }

    /// Current file first, then the rotated ones from newest to oldest.
    func fileURLs() -> [URL] {
        guard let directory else { return [] }
        return (0..<limits.files).map { directory.appendingPathComponent($0 == 0 ? "events.jsonl" : "events.\($0).jsonl") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Private, on `work`

    private func append(_ event: DiagnosticEvent) {
        let index = (start + count) % ring.count
        ring[index] = event
        if count < ring.count { count += 1 } else { start = (start + 1) % ring.count }
    }
    private func orderedRing() -> [DiagnosticEvent] {
        (0..<count).compactMap { ring[(start + $0) % ring.count] }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
    static func line(_ event: DiagnosticEvent) -> Data {
        var data = (try? encoder.encode(event)) ?? Data()
        data.append(0x0A)
        return data
    }
    static func decode(_ file: URL) -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(DiagnosticEvent.self, from: Data($0)) }
    }

    private func writePending() {
        flushScheduled = false
        guard let directory, !pending.isEmpty else { return }
        let batch = pending.reduce(into: Data()) { $0.append(Self.line($1)) }
        pending.removeAll()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let current = directory.appendingPathComponent("events.jsonl")
            if !FileManager.default.fileExists(atPath: current.path) {
                FileManager.default.createFile(atPath: current.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: batch)
            // Kept private even if something else created the file with wider permissions.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.path)
            let size = (try? current.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size >= limits.fileBytes { rotate(directory) }
            dropExpired(directory)
        } catch {
            // A diagnostic that breaks the thing it is diagnosing would be worse than no diagnostic.
        }
    }
    private func rotate(_ directory: URL) {
        let name = { (index: Int) in directory.appendingPathComponent(index == 0 ? "events.jsonl" : "events.\(index).jsonl") }
        try? FileManager.default.removeItem(at: name(limits.files - 1))
        for index in stride(from: limits.files - 2, through: 0, by: -1) {
            try? FileManager.default.moveItem(at: name(index), to: name(index + 1))
        }
        // With a single file allowed, rotating means starting it again.
        if limits.files <= 1 { try? FileManager.default.removeItem(at: name(0)) }
    }
    private func dropExpired(_ directory: URL) {
        let oldest = Date().addingTimeInterval(-limits.maxAge)
        for file in fileURLs() {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
            if modified < oldest { try? FileManager.default.removeItem(at: file) }
        }
    }
    /// Recent events of earlier runs, so the settings window has something to show right after a relaunch.
    private func loadPrevious() {
        guard let directory else { return }
        dropExpired(directory)
        let oldest = Date().addingTimeInterval(-limits.maxAge)
        var previous: [DiagnosticEvent] = []
        for file in fileURLs() {
            previous.insert(contentsOf: Self.decode(file).filter { $0.time >= oldest }, at: 0)
            if previous.count >= ring.count { break }
        }
        for var event in previous.suffix(ring.count) {
            event.id = nextID; nextID += 1
            append(event)
        }
    }
}
