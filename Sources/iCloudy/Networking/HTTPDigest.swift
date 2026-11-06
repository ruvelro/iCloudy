import Foundation
import CryptoKit

/// HTTP Digest authentication (RFC 7616, and RFC 2617 before it), which some NAS boxes and older WebDAV servers ask
/// for instead of Basic. The password never travels: each request carries a hash of it mixed with the server's nonce,
/// the method and the path. Only `qop=auth` is spoken (`auth-int` would hash every body, and no server seen insists
/// on it), with MD5, SHA-256 and their `-sess` variants.
enum HTTPDigest {
    enum Algorithm: String {
        case md5 = "MD5", md5Session = "MD5-sess", sha256 = "SHA-256", sha256Session = "SHA-256-sess"
        var isSession: Bool { self == .md5Session || self == .sha256Session }
        func hash(_ text: String) -> String {
            let data = Data(text.utf8)
            switch self {
            case .md5, .md5Session: return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case .sha256, .sha256Session: return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        /// The stronger hash wins when a server offers both.
        var strength: Int { self == .sha256 || self == .sha256Session ? 2 : 1 }
    }

    struct Challenge: Equatable {
        let realm: String
        let nonce: String
        let opaque: String?
        let algorithm: Algorithm
        /// Whether the server accepts `qop=auth`. A server that names no qop gets the RFC 2069 response.
        let qopAuth: Bool
        /// The nonce expired but the credentials were right: answer again with the new one, it is no refusal.
        let stale: Bool
    }

    /// Every challenge of a `WWW-Authenticate` header, which may hold several (`Digest …, Basic …`) once the system
    /// folds repeated headers into one. Parameter values may be quoted and contain commas.
    static func challenges(_ header: String) -> [(scheme: String, parameters: [String: String])] {
        var result: [(scheme: String, parameters: [String: String])] = []
        var index = header.startIndex
        func skipSpaces() { while index < header.endIndex, header[index] == " " || header[index] == "," || header[index] == "\t" { index = header.index(after: index) } }
        func token() -> String {
            let start = index
            while index < header.endIndex, !" \t,=".contains(header[index]) { index = header.index(after: index) }
            return String(header[start..<index])
        }
        while true {
            skipSpaces()
            guard index < header.endIndex else { break }
            let word = token()
            guard !word.isEmpty else { index = header.index(after: index); continue }
            // A word followed by `=` is a parameter of the challenge being read; any other word starts a new one.
            var probe = index
            while probe < header.endIndex, header[probe] == " " { probe = header.index(after: probe) }
            if probe < header.endIndex, header[probe] == "=", !result.isEmpty {
                index = header.index(after: probe)
                while index < header.endIndex, header[index] == " " { index = header.index(after: index) }
                var value = ""
                if index < header.endIndex, header[index] == "\"" {
                    index = header.index(after: index)
                    while index < header.endIndex, header[index] != "\"" {
                        if header[index] == "\\" { index = header.index(after: index); if index == header.endIndex { break } }
                        value.append(header[index]); index = header.index(after: index)
                    }
                    if index < header.endIndex { index = header.index(after: index) }
                } else {
                    value = token()
                    // A token68 credential (`Bearer abc==`) ends in equals signs that belong to it.
                    while index < header.endIndex, header[index] == "=" { value.append("="); index = header.index(after: index) }
                }
                result[result.count - 1].parameters[word.lowercased()] = value
            } else {
                result.append((scheme: word.lowercased(), parameters: [:]))
            }
        }
        return result
    }

    /// The Digest challenge to answer, the strongest supported one when there are several.
    static func challenge(in response: HTTPURLResponse) -> Challenge? {
        guard let header = response.value(forHTTPHeaderField: "WWW-Authenticate") else { return nil }
        return challenges(header).compactMap { item -> Challenge? in
            guard item.scheme == "digest", let realm = item.parameters["realm"], let nonce = item.parameters["nonce"], !nonce.isEmpty else { return nil }
            guard let algorithm = Algorithm(rawValue: item.parameters["algorithm"] ?? "MD5") ?? Algorithm.allCases.first(where: {
                $0.rawValue.caseInsensitiveCompare(item.parameters["algorithm"] ?? "") == .orderedSame }) else { return nil }
            let qops = (item.parameters["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            // A server that offers only auth-int cannot be answered by this client.
            if !qops.isEmpty, !qops.contains("auth") { return nil }
            return Challenge(realm: realm, nonce: nonce, opaque: item.parameters["opaque"], algorithm: algorithm,
                             qopAuth: qops.contains("auth"), stale: item.parameters["stale"]?.lowercased() == "true")
        }.max { $0.algorithm.strength < $1.algorithm.strength }
    }

    /// The `response` value of RFC 7616 section 3.4.1.
    static func response(challenge: Challenge, user: String, password: String, method: String, uri: String, count: UInt32, clientNonce: String) -> String {
        let hash = challenge.algorithm.hash
        var secret = hash("\(user):\(challenge.realm):\(password)")
        if challenge.algorithm.isSession { secret = hash("\(secret):\(challenge.nonce):\(clientNonce)") }
        let target = hash("\(method):\(uri)")
        guard challenge.qopAuth else { return hash("\(secret):\(challenge.nonce):\(target)") }
        return hash("\(secret):\(challenge.nonce):\(String(format: "%08x", count)):\(clientNonce):auth:\(target)")
    }

    /// The whole `Authorization` value for one request.
    static func authorization(challenge: Challenge, user: String, password: String, method: String, url: URL, count: UInt32,
                              clientNonce: String = HTTPDigest.clientNonce()) -> String {
        let uri = requestTarget(url)
        let answer = response(challenge: challenge, user: user, password: password, method: method, uri: uri, count: count, clientNonce: clientNonce)
        func quoted(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var fields = ["username=" + quoted(user), "realm=" + quoted(challenge.realm), "nonce=" + quoted(challenge.nonce),
                      "uri=" + quoted(uri), "algorithm=" + challenge.algorithm.rawValue, "response=" + quoted(answer)]
        if challenge.qopAuth { fields += ["qop=auth", "nc=" + String(format: "%08x", count), "cnonce=" + quoted(clientNonce)] }
        if let opaque = challenge.opaque { fields.append("opaque=" + quoted(opaque)) }
        return "Digest " + fields.joined(separator: ", ")
    }

    /// The path and query as they go on the request line, which is what the server hashes on its side.
    static func requestTarget(_ url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? "/"
        let query = components?.percentEncodedQuery.map { "?" + $0 } ?? ""
        return (path.isEmpty ? "/" : path) + query
    }

    static func clientNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

extension HTTPDigest.Algorithm: CaseIterable {}
