import Foundation

enum HTTP {
    static func form(_ values: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        return values.sorted { $0.key < $1.key }.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&").data(using: .utf8)!
    }
    static func json(_ data: Data) throws -> [String: Any] {
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CloudError.message(L("Respuesta no válida del servicio.")) }
        return result
    }

    /// Above this size an answer is parsed off the main thread: a page of a thousand items from Drive or Graph, a
    /// recursive pCloud listing or Mega's whole tree took long enough there to stall the window.
    static let backgroundParseThreshold = 32 * 1024

    /// What `JSONSerialization` returns is not `Sendable`; this carries it back from the background once, untouched.
    private struct Parsed: @unchecked Sendable { let value: Any }

    /// `JSONSerialization` on a large answer, off the main thread; small answers are parsed in place.
    static func parse(_ data: Data, fragments: Bool = false) async throws -> Any {
        let options: JSONSerialization.ReadingOptions = fragments ? [.fragmentsAllowed] : []
        guard data.count >= backgroundParseThreshold else { return try JSONSerialization.jsonObject(with: data, options: options) }
        return try await blockingIO { Parsed(value: try JSONSerialization.jsonObject(with: data, options: options)) }.value
    }

    /// `json(_:)`, off the main thread when the answer is large.
    static func object(_ data: Data) async throws -> [String: Any] {
        guard let result = try await parse(data) as? [String: Any] else { throw CloudError.message(L("Respuesta no válida del servicio.")) }
        return result
    }
    static func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let response = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
        guard (200..<300).contains(response.statusCode) else {
            let (code, message) = errorDetails(data)
            let fallback = L("El servicio devolvió HTTP \(response.statusCode).") + " " + (response.statusCode == 401 ? L("Vuelve a conectar la cuenta.") : L("Inténtalo de nuevo más tarde."))
            throw ServiceError(status: response.statusCode, detail: message ?? fallback, code: code,
                               retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? ""))
        }
    }
    /// Drive and Graph nest the error as an object; the OAuth token endpoints follow RFC 6749 with `error` and `error_description` strings.
    static func errorDetails(_ data: Data) -> (code: String?, message: String?) {
        guard let object = try? json(data) else { return (nil, nil) }
        // Dropbox describes the failure in a flat summary string alongside a tagged `error` object. It is read first:
        // the object has no message of its own, so reading it first left every Dropbox refusal as a bare "HTTP 409".
        if let summary = object["error_summary"] as? String { return (summary, DropboxErrors.message(summary)) }
        if let error = object["error"] as? [String: Any] {
            // Google says a token lacks a scope in `details` (ErrorInfo) and, on older endpoints, in `errors[].reason`.
            let reasons = ((error["details"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
                + ((error["errors"] as? [[String: Any]]) ?? []).compactMap { $0["reason"] as? String }
            if reasons.contains(ServiceError.scopeInsufficient)
                || (reasons.contains("insufficientPermissions") && (error["message"] as? String ?? "").contains("scope")) {
                return (ServiceError.scopeInsufficient, L("Esta cuenta se conectó sin permiso para tus archivos de Drive. Vuelve a conectarla y, en la pantalla de permisos de Google, marca la casilla de acceso a Google Drive."))
            }
            let code = (error["code"] as? String) ?? (error["status"] as? String)
            return (code, error["message"] as? String)
        }
        if let code = object["error"] as? String {
            return (code, (object["error_description"] as? String) ?? code)
        }
        // Box uses `code` and `message` at the top level.
        if let code = object["code"] as? String { return (code, object["message"] as? String ?? code) }
        return (nil, nil)
    }
    static func token(cloud: Cloud, values: [String: String], session: URLSession = .shared) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: cloud.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(values)
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        try validate(response, data: data)
        return try json(data)
    }
}

