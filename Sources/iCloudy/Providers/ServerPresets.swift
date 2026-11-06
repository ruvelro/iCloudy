import Foundation

/// A storage service that speaks a protocol iCloudy already has (WebDAV, SFTP or S3) at an address it can be told in
/// advance. Choosing one fills in the address, port and path, and says what the service asks for: an app password,
/// a protocol switched on in its panel, the id of a drive. Nothing here is a provider of its own; the account that
/// comes out is a plain WebDAV, SFTP or S3 account, so everything those providers do applies unchanged.
///
/// The table is data rather than code so that a new service is one entry, and so that `ServerPresetTests` can check
/// every entry the same way: an address that parses, a port in range, a documentation link over https.
struct ServerPreset: Identifiable, Equatable {
    /// What the person writes into the address template, besides the user name.
    enum Placeholder: String, CaseIterable {
        /// `{user}`: the same user name typed in the form, which some services put in the host name.
        case user
        /// `{server}`: the person's own server, for software they host themselves.
        case server
        /// `{drive}`: the numeric id of an Infomaniak kDrive, which addresses the drive rather than the account.
        case drive
        var token: String { "{" + rawValue + "}" }
    }

    let id: String
    /// The service's own name, shown as is.
    let title: String
    let cloud: Cloud
    /// Host, with placeholders. The scheme comes from `cloud`: https for WebDAV, sftp for SFTP.
    let host: String
    /// Only when it is not the protocol's default.
    let port: Int?
    /// Path appended to the host: the WebDAV root, or the folder an SFTP session starts in. May have placeholders.
    let path: String
    /// The WebDAV dialect, when the service is one iCloudy has extensions for.
    let flavor: String?
    /// For object storage, the service the S3 form opens on.
    let s3Service: S3Service?
    /// The page of the service's own documentation that explains how to connect a third-party app.
    let docs: URL
    /// What to know before connecting, in the person's language.
    let notes: String

    /// The placeholders this preset needs filled, other than the user name, which the form always asks for.
    var extraPlaceholders: [Placeholder] {
        Placeholder.allCases.filter { $0 != .user && (host + path).contains($0.token) }
    }

    /// The address the account is connected with, or nil while a placeholder is still empty. Values are trimmed, and
    /// a server typed with its scheme or a trailing slash is accepted as it is commonly pasted.
    func address(user: String, values: [Placeholder: String]) -> String? {
        guard s3Service == nil else { return nil }
        var filled = [Placeholder.user: user]
        for (key, value) in values { filled[key] = value }
        func substitute(_ text: String) -> String? {
            var result = text
            for placeholder in Placeholder.allCases where result.contains(placeholder.token) {
                var value = (filled[placeholder] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if placeholder == .server {
                    for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) { value = String(value.dropFirst(prefix.count)) }
                    while value.hasSuffix("/") { value.removeLast() }
                }
                guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { return nil }
                // A user name or a drive id goes into a host name or a path segment, and must not escape it.
                if placeholder != .server, value.contains(where: { "/?#@:".contains($0) }) { return nil }
                result = result.replacingOccurrences(of: placeholder.token, with: value)
            }
            return result
        }
        guard let host = substitute(host), let path = substitute(path) else { return nil }
        let scheme = cloud == .sftp ? "sftp://" : "https://"
        return scheme + host + (port.map { ":" + String($0) } ?? "") + path
    }

    static func == (lhs: ServerPreset, rhs: ServerPreset) -> Bool { lhs.id == rhs.id }

    /// Every preset, in the order the connection sheet lists them. Links point at each service's own help pages.
    static var all: [ServerPreset] {
        func link(_ text: String) -> URL { URL(string: text)! }
        return [
            ServerPreset(id: "nextcloud", title: "Nextcloud", cloud: .webdav, host: "{server}", port: nil,
                         path: "/remote.php/dav/files/{user}", flavor: "nextcloud", s3Service: nil,
                         docs: link("https://docs.nextcloud.com/server/latest/user_manual/en/files/access_webdav.html"),
                         notes: L("Inicia sesión en el navegador con tu servidor, también con verificación en dos pasos: Nextcloud crea una contraseña de aplicación solo para iCloudy.")),
            ServerPreset(id: "ocis", title: "ownCloud Infinite Scale", cloud: .webdav, host: "{server}", port: nil,
                         path: "/remote.php/webdav", flavor: nil, s3Service: nil,
                         docs: link("https://doc.owncloud.com/ocis/next/deployment/services/s-list/proxy.html"),
                         notes: L("oCIS inicia sesión con OpenID Connect. Usa una contraseña de aplicación si tu servidor las tiene, o un token de acceso en «Avanzado»; la autenticación básica está desactivada por omisión.")),
            ServerPreset(id: "seafile", title: "Seafile (SeafDAV)", cloud: .webdav, host: "{server}", port: nil,
                         path: "/seafdav", flavor: nil, s3Service: nil,
                         docs: link("https://manual.seafile.com/latest/extension/webdav/"),
                         notes: L("SeafDAV tiene que estar activado en el servidor. Cada biblioteca aparece como una carpeta; las bibliotecas cifradas no se ven por WebDAV.")),
            ServerPreset(id: "hetzner-sftp", title: "Hetzner Storage Box (SFTP)", cloud: .sftp, host: "{user}.your-storagebox.de", port: 23,
                         path: "/home", flavor: nil, s3Service: nil,
                         docs: link("https://docs.hetzner.com/storage/storage-box/access/access-ssh-rsync-borg/"),
                         notes: L("El usuario es el de la Storage Box (u123456). Activa «SSH Support» en Robot; el puerto 23 da SFTP completo y el 22, uno más limitado.")),
            ServerPreset(id: "hetzner-webdav", title: "Hetzner Storage Box (WebDAV)", cloud: .webdav, host: "{user}.your-storagebox.de", port: nil,
                         path: "", flavor: nil, s3Service: nil,
                         docs: link("https://docs.hetzner.com/storage/storage-box/access/access-webdav/"),
                         notes: L("Activa «WebDAV» en los ajustes de la Storage Box en Robot. El usuario es el de la Storage Box (u123456).")),
            ServerPreset(id: "koofr", title: "Koofr", cloud: .webdav, host: "app.koofr.net", port: nil,
                         path: "/dav/Koofr", flavor: nil, s3Service: nil,
                         docs: link("https://koofr.eu/help/koofr_with_webdav/"),
                         notes: L("Crea una contraseña de aplicación en Koofr (Preferencias › Contraseñas) y úsala con tu correo; la contraseña de la cuenta no sirve para WebDAV.")),
            ServerPreset(id: "yandex", title: "Yandex Disk", cloud: .webdav, host: "webdav.yandex.com", port: nil,
                         path: "", flavor: nil, s3Service: nil,
                         docs: link("https://yandex.com/support/disk-desktop/webdav-connect.html"),
                         notes: L("Yandex pide una contraseña de aplicación del tipo «Archivos» (WebDAV). Puede limitar la velocidad de las subidas por WebDAV.")),
            ServerPreset(id: "kdrive", title: "Infomaniak kDrive", cloud: .webdav, host: "{drive}.connect.kdrive.infomaniak.com", port: nil,
                         path: "", flavor: nil, s3Service: nil,
                         docs: link("https://www.infomaniak.com/en/support/faq/2409/connect-to-kdrive-via-webdav"),
                         notes: L("El ID del kDrive es el número que aparece en su dirección web (ksuite.infomaniak.com/…/kdrive/app/drive/123456). Usuario: tu correo; con verificación en dos pasos, una contraseña de aplicación.")),
            ServerPreset(id: "hidrive", title: "IONOS HiDrive", cloud: .webdav, host: "webdav.hidrive.ionos.com", port: nil,
                         path: "", flavor: nil, s3Service: nil,
                         docs: link("https://www.ionos.com/help/hidrive/"),
                         notes: L("WebDAV tiene que estar activado para el usuario en la administración de HiDrive, y no está en todos los planes. Las cuentas antiguas de STRATO usan webdav.hidrive.strato.com.")),
            ServerPreset(id: "fastmail", title: "Fastmail Files", cloud: .webdav, host: "myfiles.fastmail.com", port: nil,
                         path: "", flavor: nil, s3Service: nil,
                         docs: link("https://www.fastmail.help/hc/en-us/articles/1500000277882"),
                         notes: L("Crea una contraseña de aplicación con acceso a «Files (WebDAV)» en Ajustes › Privacidad y seguridad. El usuario es tu dirección de Fastmail.")),
            ServerPreset(id: "backblaze", title: "Backblaze B2", cloud: .s3, host: "", port: nil, path: "", flavor: nil, s3Service: .backblaze,
                         docs: link("https://www.backblaze.com/docs/cloud-storage-s3-compatible-api"),
                         notes: L("Con una clave de aplicación. La región está en la dirección S3 del bucket.")),
            ServerPreset(id: "wasabi", title: "Wasabi", cloud: .s3, host: "", port: nil, path: "", flavor: nil, s3Service: .wasabi,
                         docs: link("https://docs.wasabi.com/docs/what-are-the-service-urls-for-wasabi-s-different-storage-regions"),
                         notes: L("Con una clave de acceso de Wasabi y la región del bucket.")),
            ServerPreset(id: "r2", title: "Cloudflare R2", cloud: .s3, host: "", port: nil, path: "", flavor: nil, s3Service: .cloudflare,
                         docs: link("https://developers.cloudflare.com/r2/api/s3/api/"),
                         notes: L("Con un token de API de R2 y el ID de la cuenta de Cloudflare.")),
            ServerPreset(id: "storj", title: "Storj", cloud: .s3, host: "", port: nil, path: "", flavor: nil, s3Service: .storj,
                         docs: link("https://docs.storj.io/dcs/api/s3/s3-compatible-gateway"),
                         notes: L("Con credenciales S3 de la pasarela alojada de Storj (gateway.storjshare.io).")),
            ServerPreset(id: "idrive", title: "iDrive e2", cloud: .s3, host: "", port: nil, path: "", flavor: nil, s3Service: .idrive,
                         docs: link("https://www.idrive.com/s3-storage-e2/faq-general"),
                         notes: L("Con la dirección de tu región y una clave de acceso, las dos en el panel de iDrive e2.")),
        ]
    }
}
