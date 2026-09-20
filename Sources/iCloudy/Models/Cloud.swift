import Foundation

enum Cloud: String, Codable, CaseIterable, Identifiable {
    case google, microsoft, dropbox, box, webdav, ftp, volume, mega, o2
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return L("Google Drive")
        case .microsoft: return L("OneDrive")
        case .dropbox: return L("Dropbox")
        case .box: return L("Box")
        case .webdav: return L("WebDAV")
        case .ftp: return L("FTP")
        case .volume: return L("Volumen")
        case .mega: return L("Mega")
        case .o2: return L("O2 Cloud")
        }
    }
    var tokenURL: String { OAuthProviderSettings.settings(for: self)?.tokenEndpoint ?? "" }
    /// HTTP authorization scheme for the value stored in `Credential.accessToken`.
    var authorizationScheme: String { [.webdav, .ftp].contains(self) ? "Basic" : "Bearer" }
    /// True when the user brings their own server and credentials instead of signing in at a provider.
    var isSelfHosted: Bool { [.webdav, .ftp, .volume].contains(self) }
    /// True when connecting means typing a server address and credentials, rather than picking a folder or a browser sign-in.
    var usesPasswordLogin: Bool { [.webdav, .ftp, .mega].contains(self) }
    /// True when signing in happens on the provider's own pages, inside a window, because it cannot be reproduced
    /// from a form: O2 sends the person to Telefónica's sign-in, with a national identity number or a text message.
    var usesWebLogin: Bool { self == .o2 }
    /// True when the provider ends a session that goes unused, rather than one that has simply lasted too long.
    /// O2's server does this after about an hour, measured from its own behaviour: it survived 43 minutes of silence
    /// and was gone after 80. Its web client never notices, because an open browser tab keeps asking; an app sitting
    /// idle on someone's Mac does notice, and the account looked broken.
    var needsKeepAlive: Bool { self == .o2 }
    /// True when the provider works through an API its owner neither documents nor promises to keep. The interface
    /// says so plainly instead of letting a sudden breakage look like a bug in iCloudy.
    var isExperimental: Bool { [.mega, .o2].contains(self) }
    /// Identifier the provider gives to the top of the tree, behind iCloudy's own "root" alias.
    var rootAlias: String {
        switch self {
        case .google, .microsoft, .webdav, .ftp, .volume, .mega, .o2: return "root"
        case .dropbox: return "" // Dropbox addresses the root as an empty path
        case .box: return "0"
        }
    }
    var capabilities: CloudCapabilities { CloudCapabilities.of(self) }
}

struct CloudCapabilities {
    var oauth = true
    var search = true
    var recents = true
    var sharedWithMe = true
    var publicLinks = true
    var copy = true
    var move = true
    var quota = true
    var exportsDocuments = false
    /// False when deleting is permanent: the confirmation has to say so.
    var reversibleTrash = true
    /// The provider reports a checksum iCloudy can verify after uploading.
    var checksum = true

    static func of(_ cloud: Cloud) -> CloudCapabilities {
        switch cloud {
        case .google:
            return CloudCapabilities(exportsDocuments: true)
        case .microsoft:
            return CloudCapabilities()
        case .dropbox:
            // No "recent" or "shared with me" listing in this version; both need APIs beyond plain file browsing.
            return CloudCapabilities(recents: false, sharedWithMe: false)
        case .box:
            return CloudCapabilities(recents: false, sharedWithMe: false)
        case .webdav:
            // Plain WebDAV has no search, no sharing links and no recycle bin.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, reversibleTrash: false, checksum: false)
        case .ftp:
            // FTP has no copy, no quota report and no checksum either; deleting is final.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, copy: false, quota: false,
                                     reversibleTrash: false, checksum: false)
        case .volume:
            // The file system gives search, free space and a real Trash; only sharing links are missing.
            return CloudCapabilities(oauth: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, checksum: false)
        case .mega:
            // The whole tree arrives decrypted in one response, so search and breadcrumbs cost nothing. There is no
            // "recent" or "shared with me" listing, and no checksum to compare after uploading, because the only MAC
            // Mega stores is the one iCloudy computed itself.
            return CloudCapabilities(oauth: false, recents: false, sharedWithMe: false, checksum: false)
        case .o2:
            // Funambol has no media search and no server-side copy for third parties, and reports no checksum.
            // Deleting is a soft delete, so the item stays recoverable from O2's own bin.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     copy: false, checksum: false)
        }
    }
}
