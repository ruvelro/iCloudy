import Foundation

enum CloudError: LocalizedError {
    /// What kind of failure this is, for code that has to react to it rather than only show it. Before, only an
    /// expired session could be told apart; everything else was a sentence, and deciding by its words broke as soon
    /// as the words were translated or reworded.
    enum Kind: String, Sendable {
        /// The item, its folder or its account is not there.
        case notFound
        /// Something with that name already exists, or the item changed under the request.
        case conflict
        /// No room left on the account.
        case quota
        /// The provider understood and said no: a permission, a plan limit, a kind of item it does not handle.
        case refused
        /// Worth trying again later: the network, a busy server, a rate limit.
        case transient
        /// Only a new sign-in fixes it.
        case sessionExpired
        case other
    }

    /// A message for the person, of no particular kind. Kept as the case most code throws.
    case message(String)
    /// The provider no longer accepts the stored credential; only a new sign-in fixes it.
    case sessionExpired(String?)
    /// A message whose kind is known.
    case classified(Kind, String)

    static func notFound(_ text: String) -> CloudError { .classified(.notFound, text) }
    static func conflict(_ text: String) -> CloudError { .classified(.conflict, text) }
    static func quota(_ text: String) -> CloudError { .classified(.quota, text) }
    static func refused(_ text: String) -> CloudError { .classified(.refused, text) }
    static func transient(_ text: String) -> CloudError { .classified(.transient, text) }

    var kind: Kind {
        switch self {
        case .message: return .other
        case .sessionExpired: return .sessionExpired
        case .classified(let kind, _): return kind
        }
    }

    var errorDescription: String? {
        switch self {
        case .message(let text), .classified(_, let text): return text
        case .sessionExpired(let detail):
            let base = L("La sesión de esta cuenta ha caducado o el acceso se ha revocado. Vuelve a conectar la cuenta desde la barra lateral.")
            return detail.map { base + " " + L("Detalle del proveedor: \($0)") } ?? base
        }
    }
    var isSessionExpired: Bool { kind == .sessionExpired }

    /// The kind of any error the app meets: its own, a provider's HTTP answer, or the network's.
    static func kind(of error: Error) -> Kind {
        if let error = error as? CloudError { return error.kind }
        if let error = error as? ServiceError {
            switch error.status {
            case 401: return .sessionExpired
            case 404, 410: return .notFound
            case 409, 412: return .conflict
            case 507: return .quota
            case 403: return .refused
            default: return error.retryable ? .transient : .other
            }
        }
        if let error = error as? URLError,
           [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .dnsLookupFailed].contains(error.code) {
            return .transient
        }
        return .other
    }
}
