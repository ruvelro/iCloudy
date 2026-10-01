import Foundation

enum Cloud: String, Codable, CaseIterable, Identifiable {
    case google, microsoft, dropbox, box, webdav, ftp, sftp, volume, mega, o2
    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return L("Google Drive")
        case .microsoft: return L("OneDrive")
        case .dropbox: return L("Dropbox")
        case .box: return L("Box")
        case .webdav: return L("WebDAV")
        case .ftp: return L("FTP")
        case .sftp: return L("SFTP")
        case .volume: return L("Volumen")
        case .mega: return L("Mega")
        case .o2: return L("O2 Cloud")
        }
    }
    var tokenURL: String { OAuthProviderSettings.settings(for: self)?.tokenEndpoint ?? "" }
    /// HTTP authorization scheme for the value stored in `Credential.accessToken`.
    var authorizationScheme: String { [.webdav, .ftp, .sftp].contains(self) ? "Basic" : "Bearer" }
    /// True when the user brings their own server and credentials instead of signing in at a provider.
    var isSelfHosted: Bool { [.webdav, .ftp, .sftp, .volume].contains(self) }
    /// True when connecting means typing a server address and credentials, rather than picking a folder or a browser sign-in.
    var usesPasswordLogin: Bool { [.webdav, .ftp, .sftp, .mega].contains(self) }
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
        case .google, .microsoft, .webdav, .ftp, .sftp, .volume, .mega, .o2: return "root"
        case .dropbox: return "" // Dropbox addresses the root as an empty path
        case .box: return "0"
        }
    }
    var capabilities: CloudCapabilities {
        var capabilities = CloudCapabilities.of(self)
        capabilities.links = LinkFeatures.of(self)
        return capabilities
    }
}

/// Actions whose support depends on the kind of item as well as on the provider.
enum ItemAction { case copy, publicLink, permanentDelete }

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
    /// The provider lets iCloudy list its trash, so items can be restored or purged from the app.
    var trashListing = false
    /// The provider can delete an item for good from the app, either straight from the tree or out of its trash.
    /// False where deleting is already final (WebDAV, FTP): there is nothing more definitive to offer.
    var permanentDelete = false
    /// The whole trash can be emptied from the app, in one request or in one pass over its contents.
    var emptyTrash = false
    /// Items can be shared with named people, at a chosen level, and those grants listed and revoked. Public links
    /// are `publicLinks`; this is the other kind of sharing.
    var memberSharing = false
    /// Folders can be copied as well as files. Drive and Mega copy files only.
    var copiesFolders = true
    /// Which kinds of item a public link can be created for: O2 links folders only, Mega files only.
    var linksFiles = true
    var linksFolders = true
    /// Folders can be deleted for good as well as files. O2 purges files only.
    var purgesFolders = true
    /// How far public links can be managed: listed, created with an expiry or a password, revoked. Set from
    /// `LinkFeatures.of(_:)` at the end of this file rather than in the table above.
    var links = LinkFeatures()

    /// Whether the provider can apply `action` to every one of these items. The flags above say whether it has the
    /// action at all; this adds what depends on the kind of item, so the interface stops offering an action that the
    /// provider would only refuse after the request had gone out.
    func allows(_ action: ItemAction, on files: [CloudFile]) -> Bool {
        let folders = files.contains(where: \.isFolder), plain = files.contains { !$0.isFolder }
        switch action {
        case .copy: return copy && (copiesFolders || !folders)
        case .publicLink: return publicLinks && (linksFolders || !folders) && (linksFiles || !plain)
        case .permanentDelete: return permanentDelete && (purgesFolders || !folders)
        }
    }

    static func of(_ cloud: Cloud) -> CloudCapabilities {
        switch cloud {
        case .google:
            // Drive has no server-side copy of a folder; its files have to be copied one by one.
            return CloudCapabilities(exportsDocuments: true, trashListing: true, permanentDelete: true, emptyTrash: true, memberSharing: true,
                                     copiesFolders: false)
        case .microsoft:
            // Graph deletes for good with `permanentDelete`, but exposes no listing of the recycle bin to third parties.
            return CloudCapabilities(permanentDelete: true, memberSharing: true)
        case .dropbox:
            // No "recent" or "shared with me" listing in this version; both need APIs beyond plain file browsing.
            // Deleted entries are listed alongside the live ones and files come back through their revisions.
            // Purging exists only on Business accounts; the provider explains the refusal on the others.
            return CloudCapabilities(recents: false, sharedWithMe: false, trashListing: true, permanentDelete: true, memberSharing: true)
        case .box:
            // Box has no single "empty trash" call; iCloudy walks the trash and purges item by item.
            return CloudCapabilities(recents: false, sharedWithMe: false, trashListing: true, permanentDelete: true, emptyTrash: true, memberSharing: true)
        case .webdav:
            // Plain WebDAV has no search, no sharing links and no recycle bin.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, reversibleTrash: false, checksum: false)
        case .ftp:
            // FTP has no copy, no quota report and no checksum either; deleting is final.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, copy: false, quota: false,
                                     reversibleTrash: false, checksum: false)
        case .sftp:
            // SSH gives the channel its privacy and the server its identity, but the file protocol is as bare as
            // FTP's: no search, no links, no bin, no copy, no checksum. OpenSSH does report free space.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, copy: false, reversibleTrash: false, checksum: false)
        case .volume:
            // The file system gives search, free space and a real Trash; only sharing links are missing.
            // The user's Trash is the Finder's, and under the sandbox iCloudy cannot read it back; it can only skip
            // it and remove an item outright.
            return CloudCapabilities(oauth: false, recents: false, sharedWithMe: false,
                                     publicLinks: false, checksum: false, permanentDelete: true)
        case .mega:
            // The whole tree arrives decrypted in one response, so search and breadcrumbs cost nothing. There is no
            // "recent" or "shared with me" listing, and no checksum to compare after uploading, because the only MAC
            // Mega stores is the one iCloudy computed itself. The rubbish bin is one more folder of that tree.
            // A node copy duplicates one file's key; a folder would need every child re-keyed, and a folder link
            // needs a share key of its own. Neither is done yet, so both are offered for files only.
            return CloudCapabilities(oauth: false, recents: false, sharedWithMe: false, checksum: false,
                                     trashListing: true, permanentDelete: true, emptyTrash: true,
                                     copiesFolders: false, linksFolders: false)
        case .o2:
            // Funambol has no media search and no server-side copy for third parties, and reports no checksum.
            // Deleting is a soft delete, so the item stays recoverable from O2's own bin. The same call without the
            // soft-delete flag removes a file for good; its bin has no listing iCloudy has seen in use.
            // Links exist for folders only, and only files have a hard delete among the calls seen in use.
            return CloudCapabilities(oauth: false, search: false, recents: false, sharedWithMe: false,
                                     copy: false, checksum: false, permanentDelete: true,
                                     linksFiles: false, purgesFolders: false)
        }
    }
}

extension LinkFeatures {
    /// Public link management, provider by provider. What a plan or an administrator can still refuse (Dropbox's
    /// expiry on a free account, Drive's expiry on a personal one) is declared here and explained when it happens.
    static func of(_ cloud: Cloud) -> LinkFeatures {
        switch cloud {
        case .google:
            // An "anyone" permission can be a reader or a writer. Drive takes an expiry only where the account type
            // allows it on that kind of permission, and says so with a 400 when it does not.
            return LinkFeatures(manage: true, expiration: true, edit: true, editFolders: true, inventory: true)
        case .microsoft:
            // Graph's createLink takes an expiry and a password, both subject to the account type; there is no call
            // that lists every link of a drive.
            return LinkFeatures(manage: true, expiration: true, password: true, edit: true, editFolders: true)
        case .dropbox:
            // Editor links exist for files only; expiry, password and blocking downloads need a paid plan.
            return LinkFeatures(manage: true, expiration: true, password: true, edit: true, downloadToggle: true, inventory: true)
        case .box:
            // One shared link per item. `can_edit` is accepted on files only, and Box has no listing of all of them.
            return LinkFeatures(manage: true, expiration: true, password: true, edit: true, downloadToggle: true)
        case .mega:
            // Links are listed from the tree and revoked by removing the export. Expiry and password-protected links
            // are Pro features with their own cryptography, and neither is attempted.
            return LinkFeatures(manage: true, inventory: true)
        default:
            // Plain WebDAV, FTP, SFTP, volumes and O2. Nextcloud is a WebDAV flavour and gets `nextcloud` from its account.
            return LinkFeatures()
        }
    }
    /// Nextcloud's and ownCloud's OCS share API, enabled per account when connecting.
    static let nextcloud = LinkFeatures(manage: true, expiration: true, password: true, edit: true, editFolders: true, inventory: true)
}
