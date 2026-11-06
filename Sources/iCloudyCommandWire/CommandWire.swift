import Foundation

// What the `icloudy` command-line companion and the app say to each other. It is the only code they share, so it is
// a target of its own: the companion does not link the app, and the app does not depend on how the companion is
// written.
//
// The app is sandboxed: it cannot listen on a socket another process finds, nor write a file outside its container.
// What it can do is open URLs sent to it and connect out. So the companion listens on 127.0.0.1 on a port of its
// choosing, opens `icloudy://cli?…` naming that port and a one-time nonce, and the app connects back and answers
// in frames. Every request but `pair` carries the token the app handed out when the person approved this companion.

/// One request from the companion, carried in the query of an `icloudy://cli` URL.
public struct CLIRequest: Equatable, Sendable {
    public static let version = "1"
    public static let commands: Set<String> = ["pair", "accounts", "ls", "get", "put", "search", "open", "jobs"]

    public var command: String
    public var arguments: [String]
    public var port: UInt16
    /// Proves the connection that comes back belongs to this request.
    public var nonce: String
    /// The pairing token; nil only for `pair`.
    public var token: String?

    public init(command: String, arguments: [String], port: UInt16, nonce: String, token: String?) {
        self.command = command; self.arguments = arguments; self.port = port; self.nonce = nonce; self.token = token
    }

    public enum Invalid: Error, Equatable { case version, command, port, nonce, arguments }

    /// Reads a request from the query fields of its URL, refusing anything malformed or out of bounds.
    public init(fields: [String: String]) throws {
        guard fields["v"] == Self.version else { throw Invalid.version }
        guard let command = fields["cmd"], Self.commands.contains(command) else { throw Invalid.command }
        guard let port = fields["port"].flatMap(UInt16.init), port >= 1024 else { throw Invalid.port }
        guard let nonce = fields["nonce"], (16...128).contains(nonce.count), nonce.allSatisfy({ $0.isHexDigit }) else { throw Invalid.nonce }
        var arguments: [String] = []
        if let encoded = fields["args"], !encoded.isEmpty {
            guard encoded.count <= 16_384, let data = Data(base64URL: encoded),
                  let decoded = try? JSONDecoder().decode([String].self, from: data), decoded.count <= 16 else { throw Invalid.arguments }
            arguments = decoded
        }
        self.init(command: command, arguments: arguments, port: port, nonce: nonce, token: fields["token"].flatMap { $0.isEmpty ? nil : $0 })
    }

    public var url: URL {
        var components = URLComponents()
        components.scheme = "icloudy"
        components.host = "cli"
        var items = [URLQueryItem(name: "v", value: Self.version), URLQueryItem(name: "cmd", value: command),
                     URLQueryItem(name: "port", value: String(port)), URLQueryItem(name: "nonce", value: nonce)]
        if !arguments.isEmpty, let data = try? JSONEncoder().encode(arguments) { items.append(URLQueryItem(name: "args", value: data.base64URL)) }
        if let token { items.append(URLQueryItem(name: "token", value: token)) }
        components.queryItems = items
        return components.url!
    }
}

/// The app's answers. A plain command is one message; `get` is a message, the file's bytes and an end; `put` is a
/// message asking for the bytes, which the companion sends with an end, and a final message.
public struct CLIMessage: Codable, Equatable, Sendable {
    public var nonce: String
    public var ok: Bool
    public var error: String?
    /// What to print, one line each.
    public var lines: [String]?
    /// After `pair`: the token to keep.
    public var token: String?
    /// Before the bytes of `get`: the file's name and size.
    public var name: String?
    public var size: Int64?
    /// For `put`: send the bytes now.
    public var awaitingUpload: Bool?

    public init(nonce: String, ok: Bool, error: String? = nil, lines: [String]? = nil, token: String? = nil,
                name: String? = nil, size: Int64? = nil, awaitingUpload: Bool? = nil) {
        self.nonce = nonce; self.ok = ok; self.error = error; self.lines = lines; self.token = token
        self.name = name; self.size = size; self.awaitingUpload = awaitingUpload
    }
}

/// A frame is one type byte, a 32-bit big-endian length and the payload.
public enum CLIFrame: Equatable, Sendable {
    case message(CLIMessage)
    case data(Data)
    case end

    public static let maximumPayload = 4 * 1024 * 1024
    static let messageType: UInt8 = 0x4D, dataType: UInt8 = 0x44, endType: UInt8 = 0x45

    public enum Malformed: Error, Equatable { case type(UInt8), length(Int), payload }

    public func encoded() -> Data {
        let (type, payload): (UInt8, Data)
        switch self {
        case .message(let message): (type, payload) = (Self.messageType, (try? JSONEncoder().encode(message)) ?? Data())
        case .data(let data): (type, payload) = (Self.dataType, data)
        case .end: (type, payload) = (Self.endType, Data())
        }
        var frame = Data([type])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    /// The payload length a five-byte header announces, refusing what no frame may be.
    public static func header(_ bytes: Data) throws -> (type: UInt8, length: Int) {
        guard bytes.count == 5 else { throw Malformed.payload }
        let raw = Array(bytes)
        let type = raw[0]
        guard [messageType, dataType, endType].contains(type) else { throw Malformed.type(type) }
        let length = Int(raw[1]) << 24 | Int(raw[2]) << 16 | Int(raw[3]) << 8 | Int(raw[4])
        guard length <= maximumPayload, type != endType || length == 0 else { throw Malformed.length(length) }
        return (type, length)
    }

    public static func decode(type: UInt8, payload: Data) throws -> CLIFrame {
        switch type {
        case messageType:
            guard let message = try? JSONDecoder().decode(CLIMessage.self, from: payload) else { throw Malformed.payload }
            return .message(message)
        case dataType: return .data(payload)
        case endType: return .end
        default: throw Malformed.type(type)
        }
    }
}

/// `cuenta:/ruta`, the way the companion names a place. Account ids may themselves contain colons
/// (`webdav:nas#ana`), so the split is at the first `:/` when there is one.
public struct CLIPlace: Equatable, Sendable {
    public var account: String
    public var path: String
    public init(account: String, path: String) { self.account = account; self.path = path }
    public init?(_ text: String) {
        if let range = text.range(of: ":/") {
            account = String(text[..<range.lowerBound]); path = String(text[text.index(after: range.lowerBound)...])
        } else if let colon = text.firstIndex(of: ":") {
            account = String(text[..<colon]); path = String(text[text.index(after: colon)...])
        } else {
            account = text; path = ""
        }
        guard !account.isEmpty else { return nil }
    }
}

extension Data {
    public var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public init?(base64URL text: String) {
        var base = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base.count % 4 != 0 { base += "=" }
        self.init(base64Encoded: base)
    }
}
