import Foundation

struct ServiceError: LocalizedError {
    let status: Int
    var detail: String? = nil
    /// Machine-readable code when the body carried one: RFC 6749 `error` (e.g. `invalid_grant`) or the Graph/Drive `error.code`.
    var code: String? = nil
    /// Seconds the provider asked us to wait, from its `Retry-After` header. Waiting less is what turns one refusal
    /// into a string of them.
    var retryAfter: Double? = nil
    var errorDescription: String? { detail ?? L("El servicio devolvió HTTP \(status).") }
    var retryable: Bool { [408, 429, 500, 502, 503, 504].contains(status) }
}

