import Foundation

/// What the code around a request knows and the request itself does not: which account, which transfer, which step.
/// It travels as a task-local value, so the transfer queue sets it once and every request made on the job's behalf
/// carries it, including the ones a provider builds by hand for an upload session.
struct DiagnosticsContext: Codable, Sendable, Equatable {
    var account: String?
    var provider: String?
    var transfer: UUID?
    var stage: String?
    /// Destination of a cross-cloud transfer, whose upload half belongs to another account.
    var target: String?
    var targetProvider: String?
    var isEmpty: Bool { self == DiagnosticsContext() }
}

/// The entry points the rest of the app calls. Each one is a single line at its call site; what to keep and how to
/// redact it is decided here and in `DiagnosticsLog`.
enum Diagnostics {
    @TaskLocal static var context = DiagnosticsContext()

    /// True while the test suite runs. The suite is not sandboxed, so without this the log would pile up in the real
    /// Application Support folder of whoever ran it, as O2's record once did.
    static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    static let levelKey = "diagnosticsLevel"
    private static let saltKey = "diagnosticsSalt"

    static let shared: DiagnosticsLog = {
        let test = underTest
        let level = (UserDefaults.standard.string(forKey: levelKey)).flatMap(DiagnosticsLevel.init(rawValue:)) ?? .normal
        return DiagnosticsLog(directory: test ? nil : directory, level: test ? .normal : level, salt: test ? nil : storedSalt())
    }()
    static var directory: URL { LocalStore.directory.appendingPathComponent("Diagnostics", isDirectory: true) }

    /// One salt per Mac, so the same account hashes the same way across runs and differently on anyone else's Mac.
    private static func storedSalt() -> Data {
        if let stored = UserDefaults.standard.string(forKey: saltKey).flatMap({ Data(base64Encoded: $0) }), stored.count >= 16 { return stored }
        let salt = DiagnosticsLog.randomSalt()
        UserDefaults.standard.set(salt.base64EncodedString(), forKey: saltKey)
        return salt
    }

    /// Changes the level and remembers it. Turning the log off also stops anything already queued from being kept.
    static func setLevel(_ level: DiagnosticsLevel) {
        shared.level = level
        UserDefaults.standard.set(level.rawValue, forKey: levelKey)
    }

    /// Records an event, filling in whatever the surrounding task knows.
    static func record(_ record: DiagnosticRecord, in log: DiagnosticsLog = shared) {
        var record = record
        let context = Self.context
        if record.account == nil { record.account = context.account }
        if record.provider == nil { record.provider = context.provider }
        if record.transfer == nil { record.transfer = context.transfer }
        log.record(record)
    }

    // MARK: - HTTP

    private static let stampKey = "es.ruvelro.icloudy.diagnostics"

    /// Marks a request with the account that sends it. It is a property of the request object, never a header: it
    /// does not leave the Mac.
    static func stamp(_ request: inout URLRequest, account: Account) {
        guard URLProtocol.property(forKey: stampKey, in: request) == nil,
              let mutable = (request as NSURLRequest).mutableCopy() as? NSMutableURLRequest else { return }
        URLProtocol.setProperty(["account": account.id, "provider": account.cloud.rawValue] as NSDictionary,
                                forKey: stampKey, in: mutable)
        request = mutable as URLRequest
    }

    /// Called as URLSession creates a task, which happens synchronously inside the caller's task: the only moment the
    /// task-local context can still be read. It is kept on the task until its metrics arrive.
    static func taskCreated(_ task: URLSessionTask) {
        let context = Self.context
        guard !context.isEmpty, task.taskDescription == nil,
              let data = try? JSONEncoder().encode(context) else { return }
        task.taskDescription = String(data: data, encoding: .utf8)
    }

    /// One finished request, described from its metrics. Successful ones are details; refusals and failures are kept
    /// at the normal level.
    static func taskFinished(_ task: URLSessionTask, metrics: URLSessionTaskMetrics, log: DiagnosticsLog = shared) {
        guard let request = task.originalRequest, let url = request.url else { return }
        let http = task.response as? HTTPURLResponse
        let status = http?.statusCode
        let error = task.error
        let cancelled = (error as? URLError)?.code == .cancelled
        let severity: DiagnosticSeverity
        if cancelled { severity = .trace }
        else if error != nil { severity = .error }
        else if status == 429 || (status == 402 && http?.value(forHTTPHeaderField: "X-Hashcash") != nil) { severity = .retry }
        else if let status, status >= 400 { severity = .error }
        else { severity = .trace }
        guard log.level.records(severity) else { return }

        let stamp = URLProtocol.property(forKey: stampKey, in: request) as? [String: String]
        let context = task.taskDescription.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(DiagnosticsContext.self, from: $0) } ?? DiagnosticsContext()
        let method = request.httpMethod ?? "GET"
        let stage = Self.stage(of: task, request: request, status: status, context: context)
        var record = DiagnosticRecord(severity, stage: stage, method: method, url: url, status: status,
                                      duration: metrics.taskInterval.duration,
                                      bytesSent: task.countOfBytesSent > 0 ? task.countOfBytesSent : nil,
                                      bytesReceived: task.countOfBytesReceived > 0 ? task.countOfBytesReceived : nil,
                                      error: cancelled ? nil : error, message: cancelled ? "cancelada" : nil)
        // The account that built the request knows best; otherwise the job it belongs to, whose upload half goes to
        // the destination account of a cross-cloud transfer.
        let upload = stage.hasPrefix(DiagnosticStage.upload)
        record.account = stamp?["account"] ?? (upload && context.target != nil ? context.target : context.account)
        record.provider = stamp?["provider"] ?? provider(forHost: url.host)
            ?? (upload && context.target != nil ? context.targetProvider : context.provider)
        record.transfer = context.transfer
        if let status, status >= 400, let code = http?.value(forHTTPHeaderField: "Retry-After") {
            record.message = "Retry-After " + code
        }
        log.record(record)
    }

    /// The step a request belongs to, from what can be seen of it. Upload and download halves are told apart by the
    /// kind of task and the body sent; the rest by the shape of the path.
    static func stage(of task: URLSessionTask, request: URLRequest, status: Int?, context: DiagnosticsContext) -> String {
        let path = (request.url?.path ?? "").lowercased()
        let method = (request.httpMethod ?? "GET").uppercased()
        if status == 429 { return DiagnosticStage.rateLimit }
        if path.hasSuffix("/token") || path.contains("/oauth") || status == 401 { return DiagnosticStage.auth }
        if path.hasSuffix("/commit") || path.hasSuffix("/upload_session/finish") { return DiagnosticStage.uploadCommit }
        let sent = max(task.countOfBytesSent, Int64(request.httpBody?.count ?? 0))
        if task is URLSessionUploadTask || request.value(forHTTPHeaderField: "Content-Range") != nil || sent >= 256 * 1024 {
            return DiagnosticStage.uploadChunk
        }
        if task is URLSessionDownloadTask { return DiagnosticStage.download }
        if method == "PROPFIND" || ["/children", "/list_folder", "/items", "/list"].contains(where: path.hasSuffix)
            || path.contains("list_folder") { return DiagnosticStage.list }
        return context.stage ?? DiagnosticStage.http
    }

    /// Requests made without an account at hand, such as Mega's and O2's, still say which provider they went to.
    static func provider(forHost host: String?) -> String? {
        guard let host = host?.lowercased() else { return nil }
        let table: [(String, String)] = [
            ("googleapis.com", "google"), ("google.com", "google"),
            ("graph.microsoft.com", "microsoft"), ("onedrive.com", "microsoft"), ("sharepoint.com", "microsoft"),
            ("microsoftonline.com", "microsoft"), ("live.com", "microsoft"),
            ("dropboxapi.com", "dropbox"), ("dropbox.com", "dropbox"), ("dropboxusercontent.com", "dropbox"),
            ("box.com", "box"), ("boxcloud.com", "box"),
            ("mega.co.nz", "mega"), ("mega.nz", "mega"), ("mega.io", "mega"),
            ("o2online.es", "o2"), ("o2.de", "o2"),
        ]
        return table.first { host == $0.0 || host.hasSuffix("." + $0.0) }?.1
    }

    // MARK: - Accounts and sessions

    static func retrying(_ account: Account, method: String, url: URL?, status: Int?, attempt: Int, delay: Double) {
        record(DiagnosticRecord(.retry, stage: status == 429 ? DiagnosticStage.rateLimit : DiagnosticStage.retry,
                                provider: account.cloud.rawValue, account: account.id, method: method, url: url,
                                status: status, duration: delay, attempt: attempt,
                                message: "espera \(Int(delay.rounded())) s"))
    }
    static func tokenRenewed(_ account: Account) {
        record(DiagnosticRecord(.summary, stage: DiagnosticStage.auth, provider: account.cloud.rawValue,
                                account: account.id, message: "token renovado"))
    }
    static func tokenFailed(_ account: Account, error: Error) {
        record(DiagnosticRecord(.error, stage: DiagnosticStage.auth, provider: account.cloud.rawValue,
                                account: account.id, error: error))
    }
    static func sessionExpired(_ account: Account, reason: String?) {
        record(DiagnosticRecord(.error, stage: DiagnosticStage.auth, provider: account.cloud.rawValue,
                                account: account.id, message: "sesión caducada" + (reason.map { ": " + $0 } ?? "")))
    }

    // MARK: - Network

    static func networkChanged(online: Bool) {
        record(DiagnosticRecord(.summary, stage: DiagnosticStage.networkChange,
                                message: online ? "red disponible" : "sin red"))
    }

    // MARK: - FTP, SFTP and Mega

    /// One FTP command and the code it got back. The command goes through `DiagnosticsRedactor.command`, which keeps
    /// the verb and nothing else unless names are revealed, and never what follows `PASS`.
    static func ftp(_ line: String, host: String, account: String?, code: Int?, duration: TimeInterval, error: Error? = nil) {
        let failed = (error != nil && !(error is CancellationError)) || (code ?? 0) >= 400
        record(DiagnosticRecord(failed ? .error : .trace, stage: DiagnosticStage.ftp, provider: "ftp", account: account,
                                url: serverURL("ftp", host), status: code, duration: duration, error: error,
                                command: line))
    }
    /// One SFTP request. `argument` is the path it named, if any, which only the detailed level keeps.
    static func sftp(_ verb: String, argument: String? = nil, host: String, account: String?, duration: TimeInterval? = nil,
                     status: Int? = nil, error: Error? = nil) {
        let failed = (error != nil && !(error is CancellationError)) || (status ?? 0) != 0
        record(DiagnosticRecord(failed ? .error : .trace, stage: DiagnosticStage.sftp, provider: "sftp", account: account,
                                url: serverURL("sftp", host), status: status, duration: duration, error: error,
                                command: verb + (argument.map { " " + $0 } ?? "")))
    }
    /// Names of the SFTP version 3 requests, which are what the log shows instead of the paths they carry.
    static func sftpVerb(_ type: UInt8) -> String {
        let names: [UInt8: String] = [1: "INIT", 3: "OPEN", 4: "CLOSE", 5: "READ", 6: "WRITE", 7: "LSTAT", 8: "FSTAT",
                                      9: "SETSTAT", 11: "OPENDIR", 12: "READDIR", 13: "REMOVE", 14: "MKDIR", 15: "RMDIR",
                                      16: "REALPATH", 17: "STAT", 18: "RENAME", 200: "EXTENDED"]
        return names[type] ?? "SFTP-\(type)"
    }
    private static func serverURL(_ scheme: String, _ host: String) -> URL? {
        URL(string: scheme + "://" + (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host))
    }
    /// A Mega command that had to be repeated or failed. The command is a protocol word (`f`, `us0`, `g`…), never data.
    static func mega(_ command: String, severity: DiagnosticSeverity, code: Int? = nil, attempt: Int? = nil,
                     status: Int? = nil, error: Error? = nil, note: String) {
        var record = DiagnosticRecord(severity, stage: DiagnosticStage.mega, provider: "mega", status: status,
                                      attempt: attempt, error: error, message: "a=\(command) · \(note)")
        if let code { record.errorDomain = "Mega"; record.errorCode = String(code) }
        Self.record(record)
    }
}
