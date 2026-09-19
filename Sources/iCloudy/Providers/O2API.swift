import Foundation

/// The transport for O2 Cloud. Funambol's SAPI answers every call with the same envelope: a `data` object when it
/// worked, an `error` object with a code when it did not, and HTTP 200 in both cases. So the status code says almost
/// nothing and the body says everything.
enum O2API {
    /// Exactly what the platform's own clients ask for. The name of a field is checked, and an invented one fails
    /// the whole call with "Invalid parameter value", so nothing goes in here that has not been seen in use.
    /// The kind of media and the content type are not on this list because they are not requestable: the server
    /// returns them by itself, alongside the identifier.
    static let mediaFields = ["name", "modificationdate", "size"]
    static let pageSize = 200

    struct Failure: Error, LocalizedError {
        let code: String
        let message: String?
        /// Some errors carry a replacement value, such as a rotated validation key.
        var data: String?
        /// Which call produced it. Without this an undocumented platform is very hard to debug from a report.
        var origin: String?
        var errorDescription: String? {
            let detail = message ?? L("O2 Cloud devolvió el error \(code).")
            return origin.map { "\(detail) (\($0))" } ?? detail
        }
        /// The session is gone rather than merely stale, so signing in again is the only way forward.
        var isExpiredSession: Bool { ["SEC-1001", "SEC-1002", "SEC-1004", "SEC-1005"].contains(code) }
    }

    static func url(host: String, path: String, action: String, validationKey: String?, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/sapi/" + path
        components.queryItems = [URLQueryItem(name: "action", value: action)] + query
            + (validationKey.map { [URLQueryItem(name: "validationkey", value: $0)] } ?? [])
        return components.url!
    }
    /// Nothing here is worth reusing from a cache: the validation key travels in the query, so a cached answer would
    /// be one given to a key that has since rotated, and a listing served from disk would hide what changed.
    static func uncached(_ request: inout URLRequest) { request.cachePolicy = .reloadIgnoringLocalCacheData }

    /// The error code alone, for the diagnostic record. Never the message, which can quote a file name.
    static func errorCode(_ data: Data) -> String? {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = body["error"] as? [String: Any] else { return nil }
        return error["code"] as? String ?? "?"
    }
    /// Reads the envelope. An error in the body is turned into a Failure even though the status was 200.
    static func payload(_ data: Data) throws -> [String: Any] {
        guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw CloudError.message(L("O2 Cloud devolvió una respuesta que no se entiende."))
        }
        if let error = body["error"] as? [String: Any] {
            let code = error["code"] as? String ?? "?"
            throw Failure(code: code, message: friendly(code: code, server: error["message"] as? String),
                          data: error["data"] as? String, origin: nil)
        }
        return body["data"] as? [String: Any] ?? body
    }
    /// Turns the codes worth explaining into something a person can act on, and passes the rest through.
    private static func friendly(code: String, server: String?) -> String? {
        switch code {
        case "SEC-1001", "SEC-1002":
            return L("O2 Cloud rechazó el correo o la contraseña.")
        case "SEC-1003":
            return L("La sesión de O2 Cloud se ha renovado.")
        case "COM-1005":
            return L("O2 Cloud no admite esa operación.")
        case "COM-1004", "COM-1002":
            return L("O2 Cloud rechazó un parámetro de la petición.")
        case "PRO-1000", "PRO-1001":
            return L("La cuenta de O2 Cloud no tiene espacio suficiente.")
        case "MED-1006", "MED-1007":
            return L("Ese elemento ya no está en O2 Cloud.")
        default:
            return server
        }
    }

    /// The request one SAPI call travels in, already carrying the session.
    @MainActor
    static func request(_ path: String, action: String, query: [URLQueryItem], body: [String: Any]?, method: String?,
                        state: O2Session) throws -> URLRequest {
        var request = URLRequest(url: url(host: state.host, path: path, action: action, validationKey: state.validationKey, query: query))
        request.httpMethod = method ?? "POST"
        uncached(&request)
        state.apply(to: &request)
        if let body {
            request.setValue("application/json;charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
    }

    /// What an answer from this server means, whatever the request was for.
    ///
    /// The upload and the download used to build their own requests and skip all of this: a session that expired
    /// halfway through a transfer failed with a message about a password nobody had typed, left the account looking
    /// healthy, and threw away the renewed cookies the server had just handed back. It runs on the main actor so the
    /// session's cookies and key are read and written without another call slipping in between.
    @MainActor
    static func interpret(_ response: URLResponse, data: Data, state: O2Session,
                          path: String, action: String, sentKey: String) throws {
        guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        var arrived: [HTTPCookie] = []
        if let fields = http.allHeaderFields as? [String: String], let address = response.url {
            arrived = HTTPCookie.cookies(withResponseHeaderFields: fields, for: address)
            // A refusal comes with a brand-new anonymous session. Keeping it would replace a session that is merely
            // stale with one that was never signed in, and bury the reason.
            if http.statusCode != 401, http.statusCode != 403 { state.absorb(arrived) }
        }
        // Only the shape of the exchange, never its contents. See O2Log for what is and is not written.
        O2Log.record(O2Log.describe(path: path, action: action, status: http.statusCode,
                                    error: errorCode(data),
                                    keyChanged: state.validationKey != sentKey,
                                    cookieNames: arrived.map(\.name)))
        guard http.statusCode != 401, http.statusCode != 403 else {
            throw Failure(code: "SEC-1002", message: L("O2 Cloud rechazó la sesión. Vuelve a iniciar sesión."), data: nil,
                          origin: "\(path) \(action)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CloudError.message(L("O2 Cloud devolvió HTTP \(http.statusCode) en \(path) \(action)."))
        }
    }
    /// Reads the envelope of an answer that has already been interpreted, tagging the failure with where it happened
    /// and with the key the cookie may have brought instead of the body.
    @MainActor
    static func result(_ data: Data, state: O2Session, path: String, action: String, sentKey: String) throws -> [String: Any] {
        do { return try payload(data) }
        catch var failure as Failure {
            failure.origin = "\(path) \(action)"
            // The platform's own client, when told the key is stale and given no replacement, looks at the cookie:
            // if it no longer matches what was sent, that is the new key. Same thing here.
            if failure.code == "SEC-1003", failure.data == nil, state.validationKey != sentKey {
                failure.data = state.validationKey
            }
            throw failure
        }
    }

    @MainActor
    static func call(_ path: String, action: String, query: [URLQueryItem], body: [String: Any]?, method: String?,
                     state: O2Session, session: URLSession) async throws -> [String: Any] {
        let request = try request(path, action: action, query: query, body: body, method: method, state: state)
        let sent = state.validationKey
        let (data, response) = try await session.data(for: request)
        try interpret(response, data: data, state: state, path: path, action: action, sentKey: sent)
        return try result(data, state: state, path: path, action: action, sentKey: sent)
    }

    /// What iCloudy keeps after a web sign-in: the key every later call carries, and the cookies that identify the
    /// session. There is no password to store, because iCloudy never sees one.
    struct StoredSession: Codable {
        var validationKey: String
        var cookies: [StoredCookie]
        /// How the client that was granted this session introduces itself.
        var userAgent: String?
        struct StoredCookie: Codable {
            var name: String
            var value: String
            var domain: String
            var path: String
            var secure: Bool
        }
    }
    static func store(validationKey: String, cookies: [HTTPCookie], userAgent: String? = nil) -> String {
        let stored = StoredSession(validationKey: validationKey, cookies: cookies.map {
            StoredSession.StoredCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, secure: $0.isSecure)
        }, userAgent: userAgent)
        return (try? JSONEncoder().encode(stored)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    static func restore(_ text: String) -> (validationKey: String, cookies: [HTTPCookie], userAgent: String?)? {
        guard let stored = try? JSONDecoder().decode(StoredSession.self, from: Data(text.utf8)),
              !stored.validationKey.isEmpty else { return nil }
        let cookies = stored.cookies.compactMap { value -> HTTPCookie? in
            HTTPCookie(properties: [.name: value.name, .value: value.value, .domain: value.domain,
                                    .path: value.path.isEmpty ? "/" : value.path,
                                    .secure: value.secure ? "TRUE" : "FALSE"])
        }
        return (stored.validationKey, cookies, stored.userAgent)
    }

    /// Who the session belongs to, so the account has a name the person recognises.
    @MainActor
    static func identity(host: String, state: O2Session, session: URLSession) async throws -> String {
        let profile = try await call("profile", action: "get", query: [], body: nil, method: "GET",
                                     state: state, session: session)
        for key in ["email", "username", "userid", "msisdn", "phonenumber"] {
            if let value = profile[key] as? String, !value.isEmpty { return value }
        }
        if let user = profile["user"] as? [String: Any] {
            for key in ["email", "username", "userid"] where (user[key] as? String)?.isEmpty == false {
                return user[key] as! String
            }
        }
        return host
    }

    /// The platform's own clients leave the offset out of the first page, so iCloudy does the same.
    static func skip(_ offset: Int) -> [URLQueryItem] {
        offset > 0 ? [URLQueryItem(name: "offset", value: String(offset))] : []
    }
    /// Sizes and counts arrive as numbers in some responses and as strings in others.
    static func number(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
    /// Identifiers arrive as numbers in some responses and as strings in others.
    static func identifier(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
    /// Dates arrive in the platform's compact form, occasionally as an ordinary timestamp, and occasionally as
    /// milliseconds since 1970. All three are accepted rather than assuming which one a given server sends.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String, !text.isEmpty {
            for format in ["yyyyMMdd'T'HHmmss'Z'", "EEE, dd MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd'T'HH:mm:ss'Z'"] {
                let formatter = DateFormatter()
                formatter.dateFormat = format
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.locale = Locale(identifier: "en_US_POSIX")
                if let parsed = formatter.date(from: text) { return parsed }
            }
            if let seconds = Double(text) { return date(NSNumber(value: seconds)) }
            return CloudAPI.date(text)
        }
        if let number = value as? NSNumber {
            let milliseconds = number.doubleValue
            guard milliseconds > 0 else { return nil }
            return Date(timeIntervalSince1970: milliseconds > 100_000_000_000 ? milliseconds / 1000 : milliseconds)
        }
        return nil
    }
    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
