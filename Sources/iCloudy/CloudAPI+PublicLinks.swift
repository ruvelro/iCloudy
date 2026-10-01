import Foundation

/// Public link management through the facade. Options a provider does not support are refused here, before any
/// request goes out, so no provider ever receives a setting it would silently drop.
extension CloudAPI {
    func publicLinks(for file: CloudFile) async throws -> [PublicLink] {
        guard demo == nil else { throw CloudError.message(L("La demo no gestiona enlaces públicos.")) }
        return try await provider.publicLinks(for: file)
    }
    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink {
        guard demo == nil else { throw CloudError.message(L("La demo no gestiona enlaces públicos.")) }
        if let reason = account.capabilities.links.refusal(of: options, for: file, cloud: account.cloud) { throw CloudError.message(reason) }
        if let reason = account.limitation(.publicLink, for: [file]) { throw CloudError.message(reason) }
        return try await provider.createPublicLink(for: file, options: options)
    }
    func revokePublicLink(_ link: PublicLink) async throws {
        guard demo == nil else { throw CloudError.message(L("La demo no gestiona enlaces públicos.")) }
        guard link.canRevoke else { throw CloudError.message(L("Este enlace viene de una carpeta superior. Revócalo en esa carpeta.")) }
        try await provider.revokePublicLink(link)
    }
    func allPublicLinks() async throws -> [PublicLink] {
        guard demo == nil else { throw CloudError.message(L("La demo no gestiona enlaces públicos.")) }
        guard account.capabilities.links.inventory else { throw CloudError.message(PublicLinkNotes.noInventory(account.cloud)) }
        return try await provider.allPublicLinks()
    }
}

/// What each provider's links can and cannot do, in the words the interface shows next to them.
enum PublicLinkNotes {
    /// Shown above the creation form.
    static func creation(_ cloud: Cloud) -> String {
        switch cloud {
        case .google: return L("Google Drive tiene un único enlace para cualquiera por elemento: crearlo otra vez cambia su permiso. La caducidad depende del tipo de cuenta; si Drive no la admite, lo dice y no crea nada.")
        case .microsoft: return L("En OneDrive personal la caducidad y la contraseña necesitan Microsoft 365; en una organización, las permite o no el administrador. Si OneDrive las rechaza, el enlace no se crea.")
        case .dropbox: return L("La caducidad, la contraseña y desactivar la descarga necesitan un plan de pago de Dropbox. Los enlaces de edición solo existen para archivos.")
        case .box: return L("Box tiene un único enlace por elemento: crearlo otra vez cambia los ajustes del que ya existe. La caducidad necesita una cuenta de pago y la contraseña debe cumplir su política.")
        case .webdav: return L("Nextcloud crea un enlace nuevo cada vez, con sus propios ajustes. El servidor puede exigir contraseña o caducidad según su configuración.")
        case .mega: return L("Mega crea enlaces de archivo sin caducidad ni contraseña desde iCloudy. Revocar un enlace lo desactiva para todo el que lo tenga.")
        default: return ""
        }
    }
    /// Why the account-wide list is not available.
    static func noInventory(_ cloud: Cloud) -> String {
        switch cloud {
        case .microsoft: return L("Microsoft Graph no ofrece ninguna forma de listar todos los enlaces de una cuenta de OneDrive. Consulta los de cada elemento desde «Enlaces públicos…» en su menú.")
        case .box: return L("Box no permite listar todos los enlaces compartidos de una cuenta sin permisos de administrador. Consulta los de cada elemento desde «Enlaces públicos…» en su menú.")
        default: return L("\(cloud.title) no permite listar todos sus enlaces públicos.")
        }
    }
}
