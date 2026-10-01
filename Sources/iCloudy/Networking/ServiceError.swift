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
    /// Dropbox answers lock contention on the account with a 409 or 429 whose summary says so; it applied nothing and
    /// asks for the same request again.
    /// Google's code for a token that was granted without a scope the request needs. Renewing it changes nothing.
    static let scopeInsufficient = "ACCESS_TOKEN_SCOPE_INSUFFICIENT"
    var retryable: Bool { [408, 429, 500, 502, 503, 504].contains(status) || code.map(DropboxErrors.isBusy) == true }
}


/// Dropbox's `error_summary` is a path of tags, such as `path/not_found/..` or `path/conflict/file/...`. The common ones
/// become a sentence a person can act on; the rest are shown as Dropbox wrote them, which still beats "HTTP 409".
enum DropboxErrors {
    /// Too many writes at once on the account. Dropbox applied nothing, and the request can be sent again.
    /// An ordinary `too_many_requests` is not this: like any 429 it is retried only where repeating is harmless.
    static func isBusy(_ summary: String) -> Bool { summary.contains("too_many_write_operations") }
    static func message(_ summary: String) -> String {
        let tags = Set(summary.split(separator: "/").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        if isBusy(summary) { return L("Dropbox está procesando demasiados cambios a la vez en esta cuenta. Se volverá a intentar en unos segundos.") }
        if tags.contains("insufficient_space") { return L("No queda espacio en la cuenta de Dropbox para esta operación.") }
        if tags.contains("disallowed_name") { return L("Dropbox no admite ese nombre de archivo (por ejemplo, .DS_Store, desktop.ini o thumbs.db).") }
        if tags.contains("malformed_path") { return L("Dropbox no acepta esa ruta: revisa que el nombre no tenga caracteres no válidos ni termine en punto o espacio.") }
        if tags.contains("conflict") { return L("Ya hay un elemento con ese nombre en ese lugar de Dropbox.") }
        if tags.contains("not_found") { return L("Dropbox no encuentra ese elemento: puede que se haya movido o borrado desde otro sitio. Actualiza la carpeta.") }
        let readable = summary.trimmingCharacters(in: CharacterSet(charactersIn: "./"))
        return L("Dropbox rechazó la operación (\(readable.isEmpty ? summary : readable)).")
    }
}
