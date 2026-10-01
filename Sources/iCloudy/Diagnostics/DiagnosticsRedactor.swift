import Foundation
import CryptoKit

/// Turns whatever a caller has at hand into something that can sit in a file a person will send to somebody else.
///
/// The rule is the same at every level: no credential of any kind survives, whatever its shape — Authorization
/// headers, cookies, OAuth tokens, passwords, signatures of presigned URLs, upload session addresses (whoever holds
/// one can write into the account) and the keys of the FTP and SFTP commands. E-mail addresses become a salted hash.
/// File names and paths are the one thing the level decides: they appear only at the detailed level, which the person
/// has to accept explicitly.
///
/// It errs on the side of hiding. A long opaque string is treated as a secret even when it is an ordinary identifier,
/// because a diagnostic that loses an identifier is still useful and one that leaks a token is not.
struct DiagnosticsRedactor: Sendable {
    static let mask = "‹redactado›"
    static let hiddenName = "«…»"
    static let hiddenPath = "‹ruta›"
    static let placeholder = "{id}"

    /// Mixed into every hash, so an address cannot be recovered by hashing a list of candidates elsewhere.
    let salt: Data
    let revealNames: Bool

    init(salt: Data, revealNames: Bool) { self.salt = salt; self.revealNames = revealNames }

    // MARK: - Identifiers

    func hash(_ value: String) -> String {
        let digest = SHA256.hash(data: salt + Data(value.lowercased().utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
    /// An account identifier often carries an address (`google:ana@gmail.com`) or a server and user name.
    func account(_ id: String) -> String { "cuenta-" + hash(id) }
    func email(_ address: String) -> String { "correo-" + hash(address) }

    // MARK: - URLs

    /// Words that name an API rather than anything of the person's. Every other path segment becomes `{id}` unless
    /// names are revealed, which is what keeps file names out of WebDAV and OneDrive paths at the normal level.
    static let vocabulary: Set<String> = [
        "2", "2.0", "v1", "v1.0", "v2", "v2.0", "v3", "v4", "api", "drive", "drives", "files", "file", "folders", "folder",
        "items", "item", "children", "content", "contents", "upload", "uploads", "download", "downloads", "me", "root",
        "search", "about", "changes", "permissions", "permission", "copy", "move", "export", "trash", "restore",
        "shared", "sharedwithme", "recent", "delta", "createuploadsession", "uploadsession", "createlink", "invite",
        "list", "list_folder", "continue", "get_metadata", "upload_session", "upload_sessions", "start", "append",
        "append_v2", "finish", "finish_batch", "delete", "delete_v2", "create_folder_v2", "move_v2", "copy_v2",
        "get_temporary_link", "list_revisions", "permanently_delete", "users", "get_current_account",
        "get_space_usage", "sharing", "create_shared_link_with_settings", "list_shared_links", "list_file_members",
        "list_folder_members", "add_folder_member", "remove_folder_member", "share_folder", "oauth2", "oauth",
        "token", "authorize", "auth", "userinfo", "o", "sessions", "commit", "collaborations", "shared_items", "cs",
        "sapi", "media", "login", "pkce", "link", "links", "storage", "remote.php", "dav", "webdav", "ocs",
        "v2.php", "apps", "files_sharing", "shares", "status.php", "sites", "followedsites", "site", "lists",
        "versions", "thumbnails", "callback", "common", "rup", "dl", "ul", "cd", "get", "d", "picture", "photo",
        "audio", "video", "document", "documents", "save", "softdelete", "uploadsessions", "_api",
    ]
    /// Path segments after which whatever follows is a capability, so even the detailed level keeps it out.
    static let capabilityMarkers: Set<String> = ["rup", "uploadsession", "upload_sessions", "ul", "dl", "cd"]
    /// Hosts whose addresses are themselves capabilities: temporary download and upload links.
    static let capabilityHosts = ["userstorage.mega.co.nz", "dropboxusercontent.com", "boxcloud.com"]

    /// Host and path template of a URL. The user and password some addresses carry are never part of either.
    func url(_ url: URL) -> (host: String?, path: String) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return (nil, Self.placeholder) }
        let host = components.host?.lowercased()
        return (host, template(path: components.percentEncodedPath, query: components.percentEncodedQuery, host: host))
    }
    /// The whole address as it may be written: scheme, host and template.
    func render(_ url: URL) -> String {
        let (host, path) = self.url(url)
        let scheme = url.scheme?.lowercased() ?? "https"
        return host.map { "\(scheme)://\($0)\(path)" } ?? path
    }

    func template(path: String, query: String?, host: String?) -> String {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let lowered = segments.map { ($0.removingPercentEncoding ?? $0).lowercased() }
        // An upload session or a temporary link is redacted whole, names or not.
        let capability = host.map { host in Self.capabilityHosts.contains { host == $0 || host.hasSuffix("." + $0) } } ?? false
            || lowered.contains { Self.capabilityMarkers.contains($0.trimmingCharacters(in: CharacterSet(charactersIn: ":"))) }
        let reveal = revealNames && !capability
        let rendered = segments.map { raw -> String in
            guard !raw.isEmpty else { return raw }
            let decoded = raw.removingPercentEncoding ?? raw
            // OneDrive addresses by path as `root:/Carpeta/archivo.pdf:/content`, with colons glued to the segments.
            let colon = decoded.hasSuffix(":") ? ":" : ""
            let base = colon.isEmpty ? decoded : String(decoded.dropLast())
            if Self.vocabulary.contains(base.lowercased()) { return base + colon }
            if reveal, !Self.looksSecret(base) { return Self.stripEmails(base, self) + colon }
            return Self.placeholder + colon
        }
        var result = rendered.joined(separator: "/")
        if result.isEmpty { result = "/" }
        if let query, !query.isEmpty {
            // Keys say which API parameter was used; values may be tokens, signatures, session ids or names.
            let keys = query.split(separator: "&").map { pair -> String in
                let key = String(pair.split(separator: "=", maxSplits: 1).first ?? "")
                return (key.removingPercentEncoding ?? key) + "=…"
            }
            result += "?" + keys.joined(separator: "&")
        }
        return result
    }

    /// Long opaque strings: tokens, session ids, signatures, base64 keys. Some identifiers fall in too, on purpose.
    static func looksSecret(_ value: String) -> Bool {
        if value.hasPrefix("eyJ") { return true }
        let opaque = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_.~+=/%!$"))
        guard value.unicodeScalars.allSatisfy({ opaque.contains($0) && $0.isASCII }) else { return false }
        let letters = value.contains { $0.isLetter }, digits = value.contains { $0.isNumber }
        if value.count >= 32 { return true }
        return value.count >= 20 && letters && digits
    }

    // MARK: - Headers and JSON

    /// Headers whose value is a credential in its entirety.
    static let secretHeaders: Set<String> = ["authorization", "proxy-authorization", "cookie", "set-cookie",
                                             "x-hashcash", "x-auth-token", "x-api-key", "x-amz-security-token",
                                             "x-goog-upload-url", "location", "upload-url"]
    /// Keys whose value is a secret, wherever they appear: query strings, forms, JSON, cookies.
    static let secretKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "code", "code_verifier", "client_secret", "password",
        "passwd", "pass", "pwd", "secret", "sid", "session", "session_id", "sessionid", "jsessionid", "key", "apikey",
        "api_key", "signature", "sig", "x-amz-signature", "x-amz-credential", "x-amz-security-token", "upload_id",
        "uploadid", "upload_url", "uploadurl", "validationkey", "validation_key", "authorization", "cookie",
        "set-cookie", "csrf", "csrftoken", "state", "nonce", "otp", "assertion", "hashcash", "tempauth", "cursor",
        "session_id", "access_key", "secret_key", "private_key", "credential", "credentials", "bearer", "k", "csid",
    ]
    /// Keys whose value names something of the person's: kept only at the detailed level.
    static let nameKeys: Set<String> = [
        "path", "path_display", "path_lower", "from_path", "to_path", "name", "title", "filename", "file_name",
        "display_name", "displayname", "query", "parent_path", "destination", "source", "folder", "description",
    ]

    func header(name: String, value: String) -> String {
        let lowered = name.lowercased()
        if Self.secretHeaders.contains(lowered) || ["token", "secret", "auth", "session", "key", "cookie"].contains(where: lowered.contains) {
            return Self.mask
        }
        // Dropbox carries the arguments of a call, paths included, as JSON in a header.
        if lowered == "dropbox-api-arg" || lowered == "dropbox-api-result" { return json(text: value) ?? Self.mask }
        return text(value)
    }

    /// Redacts a JSON document, or returns nil when the text is not one.
    func json(text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["), let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
              let cleaned = try? JSONSerialization.data(withJSONObject: json(object), options: [.sortedKeys, .withoutEscapingSlashes]),
              let string = String(data: cleaned, encoding: .utf8) else { return nil }
        return string
    }
    func json(_ object: Any, key: String? = nil) -> Any {
        if let key {
            let lowered = key.lowercased()
            if Self.isSecretKey(lowered) { return Self.mask }
            if Self.nameKeys.contains(lowered), !revealNames, object is String { return Self.hiddenName }
        }
        switch object {
        case let dictionary as [String: Any]:
            return Dictionary(uniqueKeysWithValues: dictionary.map { ($0.key, json($0.value, key: $0.key)) })
        case let array as [Any]:
            return array.map { json($0) }
        case let string as String:
            return text(string)
        default:
            return object
        }
    }
    static func isSecretKey(_ key: String) -> Bool {
        let lowered = key.lowercased()
        return secretKeys.contains(lowered) || lowered.hasSuffix("_token") || lowered.hasSuffix("token")
            || lowered.hasSuffix("_secret") || lowered.hasSuffix("password") || lowered.hasPrefix("x-amz-")
    }

    // MARK: - Commands

    /// An FTP or SFTP command. The verb is always kept; its arguments only at the detailed level, and never those of
    /// the verbs that carry credentials.
    func command(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let verb = String(trimmed.prefix { $0 != " " }).uppercased()
        let argument = trimmed.dropFirst(verb.count).trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty else { return verb }
        if ["PASS", "USER", "ACCT", "AUTH", "ADAT", "PBSZ", "PROT"].contains(verb) {
            // `AUTH TLS` and `PROT P` are protocol words, not secrets, and say which way the session went.
            return ["AUTH", "PBSZ", "PROT"].contains(verb) ? verb + " " + argument : verb + " " + Self.mask
        }
        guard revealNames else { return verb + " " + Self.hiddenPath }
        return verb + " " + text(argument)
    }

    // MARK: - Free text

    /// Error messages, server answers, anything a person or a server wrote. Each rule replaces what it finds with a
    /// marker the later rules cannot see, so a URL already reduced to its template is not taken apart again.
    func text(_ input: String) -> String {
        if let structured = json(text: input) { return structured }
        var vault: [String] = []
        func keep(_ value: String) -> String {
            vault.append(value)
            return "\u{E000}\(vault.count - 1)\u{E001}"
        }
        var text = input
        // Header lines a server can echo back in an error page.
        text = Self.replace(text, #"(?im)^\s*(authorization|proxy-authorization|cookie|set-cookie|x-hashcash|x-auth-token|location)\s*:[^\r\n]*"#) { match in
            keep(match[1] + ": " + Self.mask)
        }
        text = Self.replace(text, #"(?im)(dropbox-api-arg)\s*:\s*(\{[^\r\n]*\})"#) { match in
            keep(match[1] + ": " + (self.json(text: match[2]) ?? Self.mask))
        }
        // Authorization schemes, wherever they appear.
        // `token` and `oauth` are also ordinary words, so after them only something credential-shaped is taken.
        text = Self.replace(text, #"(?i)\b(bearer|basic|digest|token|oauth)\s+([A-Za-z0-9\-._~+/=,"]{6,})"#) { match in
            let scheme = match[1].lowercased(), value = match[2]
            let credential = ["bearer", "basic", "digest"].contains(scheme) || value.contains(where: \.isNumber) || value.count >= 20
            return credential ? keep(match[1] + " " + Self.mask) : match[0]
        }
        // Addresses: reduced to host and template, which also drops the user and password some of them carry.
        text = Self.replace(text, #"(?i)\b(https?|ftps?|sftp|webdavs?|davs?)://[^\s"'<>«»]+"#) { match in
            guard let url = URL(string: match[0]) else { return keep(Self.mask) }
            return keep(self.render(url))
        }
        // JSON pairs inside a body that was not JSON as a whole, e.g. cut off by a length limit.
        text = Self.replace(text, #""([A-Za-z0-9_\-]+)"\s*:\s*"((?:[^"\\]|\\.)*)""#) { match in
            if Self.isSecretKey(match[1]) { return keep("\"\(match[1])\": \"\(Self.mask)\"") }
            if Self.nameKeys.contains(match[1].lowercased()), !self.revealNames { return keep("\"\(match[1])\": \"\(Self.hiddenName)\"") }
            return match[0]
        }
        // key=value and key: value pairs, as in forms, query strings, cookies and log lines.
        text = Self.replace(text, #"(?i)\b([A-Za-z][A-Za-z0-9_\-]*)(\s*[=:]\s*)([^\s&;,"'<>]+)"#) { match in
            Self.isSecretKey(match[1]) ? keep(match[1] + match[2] + Self.mask) : match[0]
        }
        // FTP commands that carry credentials, in transcripts and in servers' replies.
        // Servers echo them in capitals; `user` and `acct` in lower case are too often plain words to take.
        text = Self.replace(text, #"\b(USER|ACCT)\s+\S+|(?i:\b(PASS))\s+\S+"#) { match in
            keep((match[1].isEmpty ? match[2] : match[1]).uppercased() + " " + Self.mask)
        }
        text = Self.stripEmails(text, self, keep: keep)
        // JSON web tokens, then anything long and opaque enough to be a credential.
        text = Self.replace(text, #"eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.?[A-Za-z0-9_\-]*"#) { _ in keep(Self.mask) }
        text = Self.replace(text, #"[A-Za-z0-9_\-+/=.~%]{20,}"#) { match in
            Self.looksSecret(match[0]) ? keep(Self.mask) : match[0]
        }
        if !revealNames {
            // The app quotes names with «», and servers with typographic or plain quotes. An apostrophe inside a
            // word (`can't`) opens nothing.
            text = Self.replace(text, #"«[^»]*»|“[^”]*”|"[^"\n]{1,200}"|(?<![A-Za-z])'[^'\n]{1,200}'(?![A-Za-z])"#) { _ in keep(Self.hiddenName) }
            // Absolute paths, POSIX or Windows, and anything with a separator and an extension.
            // What a rule already set aside, and markup, are never part of a path.
            text = Self.replace(text, #"(?:[A-Za-z]:\\|~?/)[^\s:,;«»"'<>\x{E000}\x{E001}]*(?:/[^\s:,;«»"'<>\x{E000}\x{E001}]*)*|\b[^\s/\\:,;«»"'<>\x{E000}\x{E001}]+(?:/[^\s/\\:,;«»"'<>\x{E000}\x{E001}]+)+/?"#) { match in
                // A lone slash, or a path made only of API words and numbers (O2's `media/folder`), is not anybody's.
                let segments = match[0].split(whereSeparator: { $0 == "/" || $0 == "\\" }).map { $0.lowercased() }
                guard match[0].count > 1, !Self.isMediaType(match[0]) else { return match[0] }
                let harmless = !match[0].hasPrefix("~") && !match[0].contains(":") && !segments.isEmpty
                    && segments.allSatisfy { Self.vocabulary.contains($0) || $0.allSatisfy(\.isNumber) }
                return harmless ? match[0] : keep(Self.hiddenPath)
            }
            text = Self.replace(text, #"[^\s\x{E000}\x{E001}/\\:,;«»"'()<>\[\]]+\.([A-Za-z0-9]{1,5})\b"#) { match in
                Self.isLikelyFileName(match[0], extension: match[1]) ? keep(Self.hiddenName) : match[0]
            }
        }
        // Put back what each rule set aside.
        return Self.replace(text, "\u{E000}([0-9]+)\u{E001}") { match in
            Int(match[1]).flatMap { vault.indices.contains($0) ? vault[$0] : nil } ?? Self.mask
        }
    }

    /// `application/json` and its kind look like relative paths and are nothing of the sort.
    static func isMediaType(_ value: String) -> Bool {
        let parts = value.lowercased().split(separator: "/")
        return parts.count == 2 && ["application", "text", "image", "audio", "video", "multipart", "font", "message", "model"]
            .contains(String(parts[0])) && parts[1].allSatisfy { $0.isLetter || $0.isNumber || "+-.".contains($0) }
    }
    /// Endings that are domain names or version numbers rather than file types.
    static let notExtensions: Set<String> = ["com", "net", "org", "es", "de", "io", "nz", "co", "uk", "me", "app", "eu",
                                             "fr", "it", "info", "biz", "local", "lan", "cloud", "dev", "us", "nl",
                                             "pt", "online", "swift", "error"]
    static func isLikelyFileName(_ token: String, extension ext: String) -> Bool {
        guard !ext.allSatisfy(\.isNumber), !notExtensions.contains(ext.lowercased()) else { return false }
        // `NSURLErrorDomain`-style dotted identifiers have no lowercase file type after them.
        return ext.contains { $0.isLetter }
    }

    static func stripEmails(_ text: String, _ redactor: DiagnosticsRedactor, keep: ((String) -> String)? = nil) -> String {
        replace(text, #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#) { match in
            let hashed = redactor.email(match[0])
            return keep?(hashed) ?? hashed
        }
    }

    /// Replaces every match of `pattern`, passing the whole match and its groups to `transform`. A pattern that does
    /// not compile hides the whole text rather than letting it through untouched: a redactor has to fail closed.
    static func replace(_ text: String, _ pattern: String, _ transform: ([String]) -> String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return mask }
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let groups = (0..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            result += transform(groups)
            cursor = match.range.location + match.range.length
        }
        result += source.substring(from: cursor)
        return result
    }
}
