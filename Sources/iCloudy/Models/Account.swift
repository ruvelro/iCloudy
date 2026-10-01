import Foundation

struct Account: Codable, Identifiable, Hashable {
    let id: String
    let cloud: Cloud
    let name: String
    let email: String
    let clientID: String
    let clientSecret: String?
    /// Base URL of the WebDAV or FTP server, or the folder path of a volume. Unused by the OAuth providers.
    var serverURL: String?
    /// Security-scoped bookmark to that folder, for volume accounts under the sandbox.
    var bookmark: Data?
    /// Extra settings that only some accounts need, kept out of the main fields: the shared drive or document library
    /// this account is scoped to, whose credential it borrows, and provider flavours such as Nextcloud.
    var options: [String: String] = [:]
    /// Shared drive (Google) or document library (SharePoint) this account is restricted to, if any.
    var driveID: String? { options["driveID"] }
    /// Keychain key holding the credential. A scoped account reuses the credential of the account it was derived from.
    var credentialKey: String { options["credentialSource"] ?? id }
    /// Server dialect, for providers that share a protocol but not their extensions.
    var flavor: String? { options["flavor"] }
    var isDemo: Bool { id.hasPrefix("demo:") }
    var capabilities: CloudCapabilities {
        if isCryptomatorVault { return .cryptomatorVault(over: cloud) }
        guard !isDemo else { return CloudCapabilities(oauth: false, publicLinks: true, trashListing: true, permanentDelete: true, emptyTrash: true, memberSharing: true) }
        var base = cloud.capabilities
        // Plain WebDAV cannot share, but Nextcloud and ownCloud add their own API for it on top.
        if cloud == .webdav, flavor == "nextcloud" { base.publicLinks = true; base.memberSharing = true }
        if cloud == .webdav, flavor == "nextcloud" { base.links = .nextcloud }
        // Nextcloud keeps earlier versions of every file behind its own WebDAV collection.
        if cloud == .webdav, flavor == "nextcloud" { base.versions = true; base.deletesVersions = true }
        // "Recientes" and "Compartido conmigo" list the person's own activity, not a drive's. A shared drive or a
        // document library has neither, and asking for them inside one returns nothing or a refusal.
        if driveID != nil { base.recents = false; base.sharedWithMe = false }
        return base
    }
    /// Why `action` cannot be applied to these items in this account, or nil when it can. The provider's own reason
    /// where it has one, so the interface can explain the action instead of offering it and failing afterwards.
    func limitation(_ action: ItemAction, for files: [CloudFile]) -> String? {
        let capabilities = self.capabilities
        guard !capabilities.allows(action, on: files) else { return nil }
        let folders = files.contains(where: \.isFolder)
        switch action {
        case .copy:
            guard capabilities.copy, folders else { return L("\(cloud.title) no permite copiar desde iCloudy.") }
            switch cloud {
            case .google: return L("Google Drive no permite copiar carpetas. Copia los archivos que contiene.")
            case .mega: return L("Mega solo copia archivos, no carpetas.")
            default: return L("\(cloud.title) no copia carpetas desde iCloudy. Copia los archivos que contiene.")
            }
        case .publicLink:
            guard capabilities.publicLinks else { return L("\(cloud.title) no crea enlaces públicos desde iCloudy.") }
            if folders, !capabilities.linksFolders {
                return cloud == .mega
                    ? L("Mega comparte una carpeta con una clave de compartición aparte, un paso que iCloudy todavía no sabe dar. Crea el enlace de la carpeta desde mega.nz; los archivos sueltos sí se comparten desde aquí.")
                    : L("\(cloud.title) solo crea enlaces públicos de archivos, no de carpetas.")
            }
            return cloud == .o2
                ? L("O2 Cloud crea enlaces de carpetas. Para un archivo suelto, compártelo desde su web.")
                : L("\(cloud.title) solo crea enlaces públicos de carpetas, no de archivos sueltos.")
        case .permanentDelete:
            guard capabilities.permanentDelete, folders else { return L("\(cloud.title) no permite el borrado definitivo desde iCloudy.") }
            return cloud == .o2
                ? L("O2 Cloud solo elimina archivos de forma definitiva desde otras aplicaciones. Envía la carpeta a la papelera y vacíala desde su web.")
                : L("\(cloud.title) solo elimina archivos de forma definitiva desde iCloudy, no carpetas.")
        }
    }
    /// An account restricted to one shared drive or document library. It is a view of the parent account rather than a
    /// new sign-in: the identifier keeps the parent's prefix and the credential stays in the parent's Keychain entry.
    static func scoped(to driveID: String, named name: String, from parent: Account) -> Account {
        Account(id: parent.id + "/drive:" + driveID, cloud: parent.cloud, name: name,
                email: parent.email + " · " + name, clientID: parent.clientID, clientSecret: parent.clientSecret,
                serverURL: nil, bookmark: nil, options: ["driveID": driveID, "credentialSource": parent.id])
    }
    static let demo = Account(id: "demo:local", cloud: .google, name: L("Demo local"), email: L("Sin conexión · datos de prueba"), clientID: "", clientSecret: nil)
}

extension Account {
    enum CodingKeys: String, CodingKey { case id, cloud, name, email, clientID, clientSecret, serverURL, bookmark, options }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let email = try values.decodeIfPresent(String.self, forKey: .email) ?? ""
        self.init(id: try values.decode(String.self, forKey: .id),
                  cloud: try values.decode(Cloud.self, forKey: .cloud),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? email,
                  email: email,
                  clientID: try values.decodeIfPresent(String.self, forKey: .clientID) ?? "",
                  clientSecret: try values.decodeIfPresent(String.self, forKey: .clientSecret),
                  serverURL: try values.decodeIfPresent(String.self, forKey: .serverURL),
                  bookmark: try values.decodeIfPresent(Data.self, forKey: .bookmark),
                  options: try values.decodeIfPresent([String: String].self, forKey: .options) ?? [:])
    }
}
