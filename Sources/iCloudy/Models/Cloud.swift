import Foundation

enum Cloud: String, Codable, CaseIterable, Identifiable {
    case google, microsoft, dropbox, box, webdav, ftp, sftp, volume, mega, o2
    case pcloud
    case s3
    case azure
    case telegram
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
        case .pcloud: return L("pCloud")
        case .s3: return L("S3")
        case .azure: return L("Azure Blob")
        case .telegram: return L("Telegram")
        }
    }
    var tokenURL: String { OAuthProviderSettings.settings(for: self)?.tokenEndpoint ?? "" }
    /// HTTP authorization scheme for the value stored in `Credential.accessToken`.
    var authorizationScheme: String { [.webdav, .ftp, .sftp].contains(self) ? "Basic" : "Bearer" }
    /// True when the user brings their own server and credentials instead of signing in at a provider.
    var isSelfHosted: Bool { [.webdav, .ftp, .sftp, .volume].contains(self) }
    /// Shorthands for the table in `CloudCapabilities`, which is where these facts live.
    var usesPasswordLogin: Bool { capabilities.signIn == .password }
    var usesWebLogin: Bool { capabilities.signIn == .web }
    var needsKeepAlive: Bool { capabilities.needsKeepAlive }
    var isExperimental: Bool { capabilities.isExperimental }
    /// Identifier the provider gives to the top of the tree, behind iCloudy's own "root" alias.
    var rootAlias: String {
        switch self {
        case .google, .microsoft, .webdav, .ftp, .sftp, .volume, .mega, .o2: return "root"
        case .dropbox: return "" // Dropbox addresses the root as an empty path
        case .box: return "0"
        case .pcloud: return "d0" // folders are "d" plus their folderid, and the top one is folder 0
        case .s3, .azure, .telegram: return "root"
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
    /// How an account of the provider is connected.
    enum SignIn {
        /// At the provider's own pages in the browser, coming back with a token.
        case oauth
        /// A server address and credentials typed into a form, kept in the Keychain.
        case password
        /// The provider's own pages inside a window, because they cannot be reproduced from a form: O2 sends the
        /// person to Telefónica's sign-in, with a national identity number or a text message.
        case web
        /// A folder of this Mac picked once, which is also what grants access under the sandbox.
        case folder
    }
    var search = true
    var recents = true
    var sharedWithMe = true
    var publicLinks = true
    var copy = true
    var quota = true
    /// False when deleting is permanent: the confirmation has to say so.
    var reversibleTrash = true
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
    /// Earlier versions of a file can be listed, previewed, downloaded and restored from the app.
    var versions = false
    /// A single earlier version can also be deleted. Graph and Dropbox keep their history out of reach for that.
    var deletesVersions = false
    /// The provider draws thumbnails of pictures, videos and PDFs, shown in the grid. Its provider type implements
    /// `thumbnail(of:side:)`; `CapabilityTableTests` checks that the two agree.
    var thumbnails = false
    /// The bin gives an item back from its id alone, so ⌘Z can undo sending it there. Dropbox needs the revision its
    /// bin lists, and the Finder's Trash is out of reach of the sandbox.
    var undoesTrash = false
    /// A copy is accepted and finished later by the server, and followed in the transfers panel. OneDrive does this.
    var asyncCopy = false
    /// Links are presigned URLs that expire, whose lifetime the person chooses. S3 has no other kind.
    var temporaryLinks = false
    /// Large uploads go up in pieces that survive a dropped connection, and a retry carries on from the last piece the
    /// server confirmed. Nextcloud's chunking v2 is the WebDAV case, set per account; SFTP writes at an offset.
    var chunkedUploads = false
    /// An interrupted download carries on from the bytes already on this Mac instead of starting over. SFTP reads at
    /// any offset; `ResumableDownload` keeps the partial between attempts and checks it belongs to the same version.
    var resumesDownloads = false
    /// Items may be in the cloud only, with their bytes fetched on demand: iCloud Drive's dataless files. Listings
    /// carry each file's state, reading one waits for its download, and an item can be downloaded or evicted.
    var ubiquitousItems = false
    /// How many jobs the session runs at once, whatever the queue's setting. FTP has a single control connection,
    /// SFTP one channel, and Mega and O2 a session the server serialises (or drops requests from) when it is asked
    /// two things at once. A second job on them would only queue inside the session while showing as running.
    var sessionLimit: Int?
    var signIn = SignIn.oauth
    /// The provider ends a session that goes unused, rather than one that has simply lasted too long. O2's server
    /// does this after about an hour, measured from its own behaviour: it survived 43 minutes of silence and was gone
    /// after 80. Its web client never notices, because an open browser tab keeps asking; an idle app does.
    var needsKeepAlive = false
    /// The provider works through an API its owner neither documents nor promises to keep. The interface says so
    /// plainly instead of letting a sudden breakage look like a bug in iCloudy.
    var isExperimental = false

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

    /// Everything iCloudy knows about a provider, in one place.
    static func of(_ cloud: Cloud) -> CloudCapabilities {
        switch cloud {
        case .google:
            // Drive has no server-side copy of a folder; its files have to be copied one by one.
            return CloudCapabilities(trashListing: true, permanentDelete: true, emptyTrash: true, memberSharing: true,
                                     copiesFolders: false, versions: true, deletesVersions: true, thumbnails: true, undoesTrash: true)
        case .microsoft:
            // Graph deletes for good with `permanentDelete`, but exposes no listing of the recycle bin to third parties:
            // the bin iCloudy shows is what it deleted itself, restored by id. Nothing empties it from here.
            // Its versions can be listed, read and restored, but not deleted one by one.
            return CloudCapabilities(trashListing: true, permanentDelete: true, memberSharing: true, versions: true, thumbnails: true, asyncCopy: true)
        case .dropbox:
            // No "recent" or "shared with me" listing in this version; both need APIs beyond plain file browsing.
            // Deleted entries are listed alongside the live ones and files come back through their revisions.
            // Purging exists only on Business accounts; the provider explains the refusal on the others.
            // Revisions are listed, downloaded and restored by `rev`; there is no call to delete a single one.
            return CloudCapabilities(recents: false, sharedWithMe: false, trashListing: true, permanentDelete: true, memberSharing: true, versions: true, thumbnails: true)
        case .box:
            // Box has no single "empty trash" call; iCloudy walks the trash and purges item by item.
            // Earlier versions can be promoted back to current and deleted; on free accounts Box keeps none.
            return CloudCapabilities(recents: false, sharedWithMe: false, trashListing: true, permanentDelete: true, emptyTrash: true, memberSharing: true,
                                     versions: true, deletesVersions: true, thumbnails: true, undoesTrash: true)
        case .webdav:
            // Plain WebDAV has no sharing links and no recycle bin. It has no search either; iCloudy walks the tree.
            return CloudCapabilities(recents: false, sharedWithMe: false,
                                     publicLinks: false, reversibleTrash: false, signIn: .password)
        case .ftp:
            // FTP has no copy, no quota report and no checksum either; deleting is final. Search walks the tree.
            return CloudCapabilities(recents: false, sharedWithMe: false,
                                     publicLinks: false, copy: false, quota: false,
                                     reversibleTrash: false, sessionLimit: 1, signIn: .password)
        case .sftp:
            // SSH gives the channel its privacy and the server its identity, but the file protocol is as bare as
            // FTP's: no search (iCloudy walks the tree), no links, no bin, no copy, no checksum. OpenSSH does report free space.
            // Uploads and downloads resume by offset: a hidden partial on the server, and one on this Mac.
            return CloudCapabilities(recents: false, sharedWithMe: false,
                                     publicLinks: false, copy: false, reversibleTrash: false, chunkedUploads: true, resumesDownloads: true,
                                     sessionLimit: 1, signIn: .password)
        case .volume:
            // The file system gives search, free space and a real Trash; only sharing links are missing.
            // The user's Trash is the Finder's, and under the sandbox iCloudy cannot read it back; it can only skip
            // it and remove an item outright.
            return CloudCapabilities(recents: false, sharedWithMe: false,
                                     publicLinks: false, permanentDelete: true, thumbnails: true, signIn: .folder)
        case .mega:
            // The whole tree arrives decrypted in one response, so search and breadcrumbs cost nothing. There is no
            // "recent" or "shared with me" listing, and no checksum to compare after uploading, because the only MAC
            // Mega stores is the one iCloudy computed itself. The rubbish bin is one more folder of that tree.
            // A node copy duplicates one file's key; a folder would need every child re-keyed, and a folder link
            // needs a share key of its own. Neither is done yet, so both are offered for files only.
            return CloudCapabilities(recents: false, sharedWithMe: false, trashListing: true, permanentDelete: true, emptyTrash: true,
                                     copiesFolders: false, linksFolders: false, undoesTrash: true, sessionLimit: 1, signIn: .password, isExperimental: true)
        case .o2:
            // Funambol has no media search (iCloudy walks the tree) and no server-side copy for third parties, and reports no checksum.
            // Deleting is a soft delete, so the item stays recoverable from O2's own bin. The same call without the
            // soft-delete flag removes a file for good; its bin has no listing iCloudy has seen in use.
            // Links exist for folders only, and only files have a hard delete among the calls seen in use.
            return CloudCapabilities(recents: false, sharedWithMe: false,
                                     copy: false, permanentDelete: true,
                                     linksFiles: false, purgesFolders: false, sessionLimit: 1, signIn: .web, needsKeepAlive: true, isExperimental: true)
        case .pcloud:
            // pCloud documents no search method for third parties; iCloudy matches names over one recursive listing.
            // It has no "recent" or "shared with me" listing.
            // Deleting goes to its trash, which is listed, restored from and cleared item by item or as a whole.
            // Files list no content hash, but `checksumfile` answers one per file for uploads and downloads.
            // Revisions are listed, read and reverted to; pCloud has no call that deletes a single one.
            return CloudCapabilities(recents: false, sharedWithMe: false,
                                     trashListing: true, permanentDelete: true, emptyTrash: true, versions: true, thumbnails: true, undoesTrash: true)
        case .s3:
            // S3 has no bin, no quota and no activity feeds. Search is by key prefix only. Uploads are checked against
            // the ETag, and a link is a presigned URL: temporary by nature, and only for an object, not a prefix.
            // Versions exist on buckets with versioning on; the sheet explains how to switch it on otherwise.
            return CloudCapabilities(recents: false, sharedWithMe: false, quota: false,
                                     reversibleTrash: false, linksFolders: false, versions: true, deletesVersions: true, temporaryLinks: true, signIn: .password)
        case .azure:
            // Containers are the roots and folders are prefixes, as in S3. No bin iCloudy can list (soft delete is an
            // account setting it cannot read back), no quota, prefix search only. Links are SAS URLs signed with the
            // account key: temporary, and for blobs only. Blocks resume; downloads are checked against Content-MD5.
            // The API is documented, so it is not `isExperimental`; the form says it has not met a real account yet.
            return CloudCapabilities(recents: false, sharedWithMe: false, quota: false,
                                     reversibleTrash: false, linksFolders: false, temporaryLinks: true, chunkedUploads: true,
                                     signIn: .password)
        case .telegram:
            // The tree is an index iCloudy keeps itself, pinned in the channel, so search, renaming, moving and
            // copying are local and instant, and copying moves no bytes at all. A channel is nobody's timeline, so
            // there is no "recent" and no "shared with me"; a private one has no public address; and Telegram
            // publishes no quota for what a channel holds. The bin stops listing an item and never deletes a
            // message, so it is reversible from the Telegram app but not listed here. One job at a time: a bot may
            // post twenty messages a minute to a chat, and every change rewrites the one pinned index.
            // The Bot API is documented; it is experimental because Telegram does not offer this as storage.
            return CloudCapabilities(recents: false, sharedWithMe: false, publicLinks: false, quota: false,
                                     sessionLimit: 1, signIn: .password, isExperimental: true)
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
        case .pcloud:
            // One account-wide list of links: listed, made and revoked. Expiry is for paid plans and not offered.
            return LinkFeatures(manage: true, inventory: true)
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
