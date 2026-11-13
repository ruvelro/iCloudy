import Foundation

/// The numbers Telegram imposes on a bot, and the ones iCloudy picks to stay under them.
enum TelegramLimits {
    /// A bot downloads at most 20 MB through `getFile`, whatever it was able to upload. Everything is therefore cut
    /// into parts below that ceiling, and 19 MiB leaves room for the multipart envelope. Every part but the last is
    /// exactly this size, which is what lets a resumed upload skip the ones already sent without reading them again.
    /// A `var` for one reason: the tests set it to a few hundred bytes so the part-splitting can be exercised
    /// without pushing forty megabytes through a stubbed URL protocol. `TelegramTests` pins the real value. Nothing
    /// but a test ever writes it, which is why it may be unchecked.
    nonisolated(unsafe) static var part: Int64 = 19 * 1024 * 1024
    /// A bot may not post more than twenty messages a minute to the same chat. Three seconds between parts stays
    /// under that without ever being told off, and sets the ceiling of this provider at roughly 6 MB/s.
    /// Also a `var`, and for the same reason: a test that waited this out would take minutes.
    nonisolated(unsafe) static var spacing: TimeInterval = 3
    /// Longest wait iCloudy honours when Telegram answers 429 with a `retry_after`. Beyond this the transfer fails
    /// with the provider's own number in the message, instead of sitting there for an hour saying nothing.
    static let maxBackoff: Double = 60
    /// The index is a document like any other, so it also has to fit under the download ceiling. At roughly 200
    /// bytes per entry this is tens of thousands of files, and a change that would pass it is refused. It is its
    /// own constant, not `part`: the tests shrink `part`, and the index has to keep its real ceiling meanwhile.
    static let indexCeiling: Int64 = 19 * 1024 * 1024
    static let indexName = "icloudy-index.json"
}

/// One piece of a file, as it lives in the channel.
///
/// `fileID` is what downloads it, and it belongs to the bot that uploaded it: another bot cannot use it, and the
/// Bot API offers no way to read a message by its identifier. That is the whole reason the index exists, and the
/// reason the bot is the key to the account.
struct TelegramPart: Codable, Hashable, Sendable {
    var fileID: String
    var messageID: Int
    var size: Int64
}

/// One file or folder. A folder is only ever an entry here: nothing is created on Telegram's side for it.
struct TelegramNode: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var parent: String
    var name: String
    var folder: Bool
    var size: Int64 = 0
    var mime: String = "application/octet-stream"
    var modified: Date = Date()
    /// SHA-256 of the whole file, computed from the very bytes that were sent. Telegram reports no checksum of its
    /// own, so this is the only thing a download can be verified against — and it is verified against it.
    var sha256: String?
    var parts: [TelegramPart] = []
    /// When the item was sent to the bin. Its messages stay in the channel, so this is reversible from Telegram.
    var deleted: Date?
}

/// The whole tree of a channel, as iCloudy keeps it.
///
/// It is a document pinned in the channel itself, because the Bot API cannot read history: a bot sees the messages
/// that arrive while it is listening and nothing else. Without this file the channel is a heap of parts with no
/// names, no folders and no order. It is read once when the account is opened and written back after every change.
struct TelegramIndex: Codable, Sendable {
    var version = 1
    var updated = Date()
    var nodes: [TelegramNode] = []

    static func decode(_ data: Data) throws -> TelegramIndex {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(TelegramIndex.self, from: data) }
        catch {
            throw CloudError.message(L("El índice del canal de Telegram no se puede leer. No se tocará nada: revisa el mensaje fijado del canal antes de seguir."))
        }
    }
    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    func node(_ id: String) -> TelegramNode? { nodes.first { $0.id == id && $0.deleted == nil } }
    func children(of parent: String) -> [TelegramNode] {
        nodes.filter { $0.parent == parent && $0.deleted == nil }
    }
    /// Every descendant of a folder, itself included. Used by move, copy and bin, which act on whole subtrees.
    func subtree(of id: String) -> [TelegramNode] {
        var found: [TelegramNode] = [], frontier = [id]
        var guardrail = 0
        while let current = frontier.popLast(), guardrail < 100_000 {
            guardrail += 1
            guard let node = self.node(current) else { continue }
            found.append(node)
            if node.folder { frontier += children(of: current).map(\.id) }
        }
        return found
    }
    /// True when moving `id` into `destination` would put a folder inside itself.
    func wouldLoop(_ id: String, into destination: String) -> Bool {
        var current = destination, steps = 0
        while current != "root", steps < 1000 {
            if current == id { return true }
            guard let node = node(current) else { return false }
            current = node.parent; steps += 1
        }
        return false
    }
    mutating func replace(_ node: TelegramNode) {
        if let position = nodes.firstIndex(where: { $0.id == node.id }) { nodes[position] = node }
        else { nodes.append(node) }
        updated = Date()
    }
}

/// An open channel: the bot that speaks for it, the tree, and where the tree is pinned. It lives on the main actor,
/// like the provider, so a running index read can hand it to every caller waiting on it.
@MainActor
final class TelegramSession {
    let token: String
    let chatID: String
    var index = TelegramIndex()
    var loaded = false
    /// The message holding the index, and the identity of the document it held when it was read. Writing checks
    /// both: if another Mac has written in the meantime, this one refuses rather than overwriting the newer tree.
    var indexMessage: Int?
    var indexFingerprint: String?
    /// Set when `indexMessage` or `indexFingerprint` changed and the Keychain copy is behind.
    var renewed = false
    /// When the last message was posted, so the pacing between parts is real and not a hope.
    var lastSend: Date?
    init(token: String, chatID: String) { self.token = token; self.chatID = chatID }

    /// Waits out whatever is left of the gap between two posts to the same chat.
    func pace() async throws {
        if let lastSend {
            let waited = Date().timeIntervalSince(lastSend)
            if waited < TelegramLimits.spacing {
                try await Task.sleep(for: .seconds(TelegramLimits.spacing - waited))
            }
        }
        lastSend = Date()
    }
    /// What goes in the Keychain beside the token: where the index was last seen. It is a recovery hint, not a
    /// secret, and it is what lets iCloudy find an index somebody unpinned by hand.
    var bookmark: String {
        var values: [String: Any] = [:]
        if let indexMessage { values["index"] = indexMessage }
        if let indexFingerprint { values["fingerprint"] = indexFingerprint }
        guard !values.isEmpty, let data = try? JSONSerialization.data(withJSONObject: values) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
    func adopt(bookmark: String) {
        guard let data = bookmark.data(using: .utf8),
              let values = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        indexMessage = values["index"] as? Int
        indexFingerprint = values["fingerprint"] as? String
    }
}

/// The Bot API, which is plain HTTPS and JSON. Nothing here needs a dependency, and nothing here is undocumented:
/// what makes the provider experimental is not the protocol but what Telegram may decide about using it this way.
enum TelegramAPI {
    struct Failure: LocalizedError, Sendable {
        let status: Int
        let code: Int
        let detail: String
        let retryAfter: Double?
        var errorDescription: String? { detail }
        /// The bot has been revoked, removed from the channel or stripped of its rights. Only reconnecting helps.
        var isRevoked: Bool { code == 401 || code == 403 }
    }

    /// Every call addresses the bot by putting its token in the path, so nothing here goes through `CloudAPI.request`:
    /// that one sets an `Authorization` header, which Telegram neither reads nor should ever be handed.
    static func endpoint(token: String, method: String, query: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.telegram.org"
        components.path = "/bot\(token)/\(method)"
        if !query.isEmpty { components.queryItems = query }
        return components.url
    }
    /// The address the bytes of a file come from, once `getFile` has said where it is.
    static func contentURL(token: String, path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.telegram.org"
        components.path = "/file/bot\(token)/\(path)"
        return components.url
    }
    /// Keeps the token out of anything shown, logged or written to disk. A bot token is a password: whoever reads
    /// it owns the channel's contents, and the token is in every URL this file builds.
    static func redact(_ text: String, token: String) -> String {
        guard token.count > 8 else { return text }
        return text.replacingOccurrences(of: token, with: "···")
    }
    /// Reads Telegram's envelope. Success is `{"ok":true,"result":…}`; failure carries `error_code`, `description`
    /// and, when it is a rate limit, `parameters.retry_after`.
    static func result(_ data: Data, response: URLResponse, token: String) throws -> [String: Any] {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if object?["ok"] as? Bool == true {
            return (object?["result"] as? [String: Any]) ?? [:]
        }
        let code = (object?["error_code"] as? Int) ?? status
        let described = (object?["description"] as? String) ?? L("Telegram devolvió HTTP \(status).")
        let after = ((object?["parameters"] as? [String: Any])?["retry_after"] as? NSNumber)?.doubleValue
        throw Failure(status: status, code: code, detail: redact(described, token: token), retryAfter: after)
    }

    /// What goes in the file part of a multipart request: bytes already in hand, or a window onto a file on disk.
    enum Body {
        case bytes(Data)
        case window(URL, offset: Int64, length: Int64)
    }
    /// Writes a multipart body to a temporary file, copying the source in blocks. A 19 MiB part is small enough to
    /// hold in memory and large enough that doing it for every part of a big upload is not worth it.
    static func envelope(fields: [String: String], part: String, filename: String, mime: String,
                                     body: Body, boundary: String) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("telegram-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CloudError.message(L("No se pudo preparar el envío a Telegram."))
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        var header = Data()
        for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
            header.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        // A quotation mark would end the header early, and a newline would forge one.
        let safe = filename.replacingOccurrences(of: "\"", with: "'")
            .components(separatedBy: .newlines).joined(separator: " ")
        header.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part)\"; filename=\"\(safe)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        try output.write(contentsOf: header)

        switch body {
        case .bytes(let data):
            try output.write(contentsOf: data)
        case .window(let source, let offset, let length):
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            try input.seek(toOffset: UInt64(offset))
            var remaining = length
            while remaining > 0 {
                try Task.checkCancellation()
                let wanted = Int(min(remaining, 4 * 1024 * 1024))
                let chunk = try await blockingIO { try input.read(upToCount: wanted) ?? Data() }
                guard !chunk.isEmpty else { throw CloudError.message(L("El origen se quedó corto durante la subida.")) }
                try await blockingIO { try output.write(contentsOf: chunk) }
                remaining -= Int64(chunk.count)
            }
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return target
    }
}

/// Reports how much of a part has left this Mac, offset by everything already sent for the same file. It is a
/// `RedirectGuard` like every other upload delegate here, and it honours the account's bandwidth limit.
final class TelegramUploadReporter: RedirectGuard, @unchecked Sendable {
    private let base: Int64
    private let total: Int64
    private let progress: (Int64, Int64) -> Void
    private let throttle = TaskThrottle(TransferThrottle.active?.upload)
    init(base: Int64, total: Int64, progress: @escaping (Int64, Int64) -> Void) {
        self.base = base; self.total = total; self.progress = progress
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        throttle?.pass(bytesSent, of: task)
        let sent = min(base + totalBytesSent, total)
        let report = progress, ceiling = total
        Task { @MainActor in report(sent, ceiling) }
    }
}
