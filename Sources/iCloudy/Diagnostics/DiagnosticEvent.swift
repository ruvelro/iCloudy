import Foundation

/// How much the diagnostic log keeps. The default keeps what explains a problem without describing anybody's files.
enum DiagnosticsLevel: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Nothing is recorded, not even errors.
    case off
    /// Errors, retries, rate limits and summaries. Paths are reduced to their API shape and file names never appear.
    case normal
    /// Every request and command as well, with paths and names. Only after the person has accepted it explicitly.
    case detailed

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return L("Desactivado")
        case .normal: return L("Normal")
        case .detailed: return L("Detallado")
        }
    }
    func records(_ severity: DiagnosticSeverity) -> Bool {
        switch self {
        case .off: return false
        case .normal: return severity != .trace
        case .detailed: return true
        }
    }
    /// Whether file names, paths and command arguments may be written. Secrets are never written at any level.
    var revealsNames: Bool { self == .detailed }
}

/// Why an event was written, which is also what decides whether the normal level keeps it.
enum DiagnosticSeverity: String, CaseIterable, Identifiable, Codable, Sendable {
    case error
    /// A request repeated after a refusal, a rate limit or a dropped connection.
    case retry
    /// The outcome of something larger: a transfer, a token renewal, the network coming and going.
    case summary
    /// A provider's own journal, kept at the normal level because it is the only way to see what an undocumented
    /// server did. O2's record of every exchange lives here, as it always has.
    case notice
    /// One successful request or command. Only the detailed level keeps these.
    case trace

    var id: String { rawValue }
    var title: String {
        switch self {
        case .error: return L("Errores")
        case .retry: return L("Reintentos")
        case .summary: return L("Resúmenes")
        case .notice: return L("Registro del proveedor")
        case .trace: return L("Detalle")
        }
    }
}

/// The step an event belongs to. Plain strings so that a provider added later can name its own without touching this.
enum DiagnosticStage {
    static let auth = "auth"
    static let list = "list"
    static let http = "http"
    static let upload = "upload"
    static let uploadChunk = "upload.chunk"
    static let uploadCommit = "upload.commit"
    static let download = "download"
    static let transfer = "transfer"
    static let verify = "verify"
    static let retry = "retry"
    static let rateLimit = "rate-limit"
    static let networkChange = "network-change"
    static let ftp = "ftp"
    static let sftp = "sftp"
    static let mega = "mega"
    static let o2 = "o2"
}

/// One line of `events.jsonl`. Every field has already been through the redactor by the time an event exists: there
/// is no raw form of it anywhere, in memory or on disk.
struct DiagnosticEvent: Codable, Identifiable, Equatable, Sendable {
    /// Increases within a run; only used to tell events apart in the interface.
    var id: UInt64 = 0
    var time: Date
    var severity: DiagnosticSeverity
    var stage: String
    /// `Cloud.rawValue` of the provider involved, when known.
    var provider: String?
    /// The account, as a salted hash: stable within this Mac, meaningless outside it.
    var account: String?
    /// The first block of the transfer's identifier, enough to follow one job through its events.
    var transfer: String?
    var method: String?
    var host: String?
    /// The path with identifiers, names and query values replaced, e.g. `/drive/v3/files/{id}?fields=…`.
    var path: String?
    var status: Int?
    var durationMs: Int?
    var bytesSent: Int64?
    var bytesReceived: Int64?
    var attempt: Int?
    var errorDomain: String?
    var errorCode: String?
    var message: String?

    // The identifier is not written: it only tells events apart within one run.
    enum CodingKeys: String, CodingKey {
        case time, severity, stage, provider, account, transfer, method, host, path, status, durationMs, bytesSent,
             bytesReceived, attempt, errorDomain, errorCode, message
    }
}

/// What a caller hands to the log. It may still hold raw values (a URL with a token in it, an error that echoes one):
/// the log redacts it before it becomes a `DiagnosticEvent`, off the caller's thread.
struct DiagnosticRecord: Sendable {
    var severity: DiagnosticSeverity
    var stage: String
    var provider: String?
    /// Raw account identifier; hashed before it is kept.
    var account: String?
    var transfer: UUID?
    var method: String?
    var url: URL?
    var status: Int?
    var duration: TimeInterval?
    var bytesSent: Int64?
    var bytesReceived: Int64?
    var attempt: Int?
    var errorDomain: String?
    var errorCode: String?
    /// Free text; redacted like any server answer.
    var message: String?
    /// An FTP or SFTP command line, which has its own rules: the verb always, the arguments only at the detailed
    /// level, and never what follows `PASS`.
    var command: String?

    init(_ severity: DiagnosticSeverity, stage: String, provider: String? = nil, account: String? = nil,
         transfer: UUID? = nil, method: String? = nil, url: URL? = nil, status: Int? = nil,
         duration: TimeInterval? = nil, bytesSent: Int64? = nil, bytesReceived: Int64? = nil, attempt: Int? = nil,
         error: Error? = nil, message: String? = nil, command: String? = nil) {
        self.severity = severity; self.stage = stage; self.provider = provider; self.account = account
        self.transfer = transfer; self.method = method; self.url = url; self.status = status
        self.duration = duration; self.bytesSent = bytesSent; self.bytesReceived = bytesReceived
        self.attempt = attempt; self.message = message; self.command = command
        if let error { describe(error) }
    }

    /// Domain and code of an error, plus its description as a message when none was given.
    mutating func describe(_ error: Error) {
        if let service = error as? ServiceError {
            errorDomain = "ServiceError"
            errorCode = service.code ?? String(service.status)
            if status == nil { status = service.status }
        } else {
            let ns = error as NSError
            errorDomain = ns.domain
            errorCode = String(ns.code)
        }
        if message == nil { message = error.localizedDescription }
    }
}
