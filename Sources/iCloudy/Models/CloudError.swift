import Foundation

enum CloudError: LocalizedError {
    case message(String)
    /// The provider no longer accepts the stored credential; only a new sign-in fixes it.
    case sessionExpired(String?)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .sessionExpired(let detail):
            let base = "La sesión de esta cuenta ha caducado o el acceso se ha revocado. Vuelve a conectar la cuenta desde la barra lateral."
            return detail.map { base + " Detalle del proveedor: \($0)" } ?? base
        }
    }
    var isSessionExpired: Bool { if case .sessionExpired = self { return true } else { return false } }
}
