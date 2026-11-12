import Foundation

/// A WebDAV service whose address follows a known shape, so nobody has to go looking for it. Choosing one fills in
/// the address with the parts that are the person's own left to type; nothing else about the connection changes.
struct WebDAVPreset: Identifiable, Equatable {
    let id: String
    let title: String
    /// The address, with `{servidor}` and `{usuario}` where the person's own values go.
    let template: String
    /// What to know before typing the password: most of these want one made for applications.
    let hint: String
    /// Nextcloud and ownCloud add a bin, versions and sharing on top of WebDAV.
    var nextcloud = false

    /// The address with what is known filled in. A part still unknown is left as its placeholder, which the form
    /// refuses to send.
    func address(server: String = "", user: String = "") -> String {
        var address = template
        if !server.isEmpty { address = address.replacingOccurrences(of: "{servidor}", with: server) }
        if !user.isEmpty { address = address.replacingOccurrences(of: "{usuario}", with: user) }
        return address
    }
    /// True while the address still has a part only the person can supply.
    static func isIncomplete(_ address: String) -> Bool { address.contains("{servidor}") || address.contains("{usuario}") }

    static let all: [WebDAVPreset] = [
        WebDAVPreset(id: "nextcloud", title: "Nextcloud", template: "https://{servidor}/remote.php/dav/files/{usuario}",
                     hint: L("Con verificación en dos pasos, crea una contraseña de aplicación en Ajustes › Seguridad."), nextcloud: true),
        WebDAVPreset(id: "owncloud", title: "ownCloud", template: "https://{servidor}/remote.php/dav/files/{usuario}",
                     hint: L("Con verificación en dos pasos, crea una contraseña de aplicación en Ajustes › Seguridad."), nextcloud: true),
        WebDAVPreset(id: "synology", title: "Synology (WebDAV Server)", template: "https://{servidor}:5006",
                     hint: L("Instala el paquete WebDAV Server en el NAS. 5006 es su puerto HTTPS; añade detrás la carpeta compartida si quieres entrar en una.")),
        WebDAVPreset(id: "koofr", title: "Koofr", template: "https://app.koofr.net/dav/Koofr",
                     hint: L("Crea una contraseña de aplicación en Preferencias › Contraseña; la de tu cuenta no sirve aquí.")),
        WebDAVPreset(id: "hetzner", title: "Hetzner Storage Box", template: "https://{usuario}.your-storagebox.de",
                     hint: L("El usuario es el de la Storage Box (u123456) y WebDAV tiene que estar activado en su panel.")),
        WebDAVPreset(id: "hidrive", title: "HiDrive (Strato / IONOS)", template: "https://webdav.hidrive.strato.com",
                     hint: L("El acceso por WebDAV depende de la tarifa; actívalo en la configuración de la cuenta.")),
        WebDAVPreset(id: "yandex", title: "Yandex Disk", template: "https://webdav.yandex.com",
                     hint: L("Crea una contraseña de aplicación para «Archivos» en la seguridad de tu cuenta de Yandex.")),
        WebDAVPreset(id: "fastmail", title: "Fastmail Files", template: "https://myfiles.fastmail.com",
                     hint: L("Crea una contraseña de aplicación con acceso a archivos (WebDAV).")),
    ]
}
