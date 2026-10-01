import Foundation

/// Operations consumed by the application. Each implementation owns its protocol and session state.
@MainActor
protocol CloudProvider: CloudSession {
    func list(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile]
    func createFolder(name: String, parent: String) async throws -> String
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest
    func rename(file: CloudFile, name: String) async throws
    func move(file: CloudFile, to destination: String) async throws
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)?) async throws
    func trash(file: CloudFile) async throws
    /// Puts an item listed under `Collection.trash` back where it was, or at the root when the provider forgot.
    func restore(file: CloudFile) async throws
    /// Removes an item for good, whether it sits in the trash or still in the tree. Nothing brings it back.
    func deletePermanently(file: CloudFile) async throws
    /// Purges everything in the provider's trash.
    func emptyTrash() async throws
    func publicLink(for file: CloudFile) async throws -> URL
    /// Who has access to the item today, the owner and public links included.
    func permissions(for file: CloudFile) async throws -> [SharePermission]
    /// Gives `recipient` (an e-mail address, or a user name where the server has them) access at `role`.
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws
    /// Public links on one item, with what each lets people do.
    func publicLinks(for file: CloudFile) async throws -> [PublicLink]
    /// Creates a link with these options, already checked against `LinkFeatures`. A provider that refuses one of them
    /// throws its reason; it never hands back a link without the expiry or password that was asked for.
    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink
    func revokePublicLink(_ link: PublicLink) async throws
    /// Every public link the account has created, where the provider can enumerate them.
    func allPublicLinks() async throws -> [PublicLink]
    func searchPage(term: String, cursor: String?, filters: SearchFilters, referenceDate: Date) async throws -> SearchPage
    func folderTrail(id: String) async throws -> [CloudFile]
    func storageQuota() async throws -> StorageQuota
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange
    func rootID() async throws -> String
    func availableDrives() async throws -> [RemoteDrive]
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async
    var requiresVerifiedLegacyCheckpoint: Bool { get }
    func canResumeWithoutSource(_ checkpoint: UploadCheckpoint?) -> Bool
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws
    /// The item as the provider describes it now, asked for after a download fails its check. nil when the provider
    /// has no cheap way to describe a single item, and the mismatch is then reported as it is.
    func currentMetadata(of file: CloudFile) async throws -> CloudFile?
    /// False for items whose listed size and checksum are known not to describe the bytes a download returns.
    func canVerifyDownload(of file: CloudFile) -> Bool
    /// Earlier versions of a file, newest first, the current one included and marked. Defaults live in
    /// `CloudProvider+Versions.swift` and refuse with the reason.
    func versions(of file: CloudFile) async throws -> [FileVersion]
    /// The request that reads one version's bytes, or its export when `exportMime` is set (Google documents).
    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest
    /// Makes `version` the file's content again. Every provider keeps the history: what was current becomes a version.
    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws
    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws
    /// The checksum to check a download against when the listing carried none, asked for right before the download
    /// so that it describes the same version. nil where the provider has no such call.
    func downloadChecksum(of file: CloudFile) async throws -> ContentHash?
    /// The checksum a download of `file` can be held to: the listed one, unless the provider has since learnt that
    /// it does not describe the content (an S3 ETag of an object encrypted with KMS looks like an MD5 and is not).
    func verifiableChecksum(of file: CloudFile) -> ContentHash?
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt
    func resumeCommittedUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt?
}

extension CloudProvider {
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        RemoteIdentityChange(oldID: file.id, newID: file.id, name: name, descendants: file.isFolder)
    }
    var requiresVerifiedLegacyCheckpoint: Bool { false }
    func restore(file: CloudFile) async throws { throw CloudError.message(L("\(account.cloud.title) no permite restaurar desde iCloudy.")) }
    func deletePermanently(file: CloudFile) async throws { throw CloudError.message(L("\(account.cloud.title) no permite el borrado definitivo desde iCloudy.")) }
    func emptyTrash() async throws { throw CloudError.message(L("\(account.cloud.title) no permite vaciar la papelera desde iCloudy.")) }
    func permissions(for file: CloudFile) async throws -> [SharePermission] { throw CloudError.message(L("\(account.cloud.title) no permite compartir con personas desde iCloudy.")) }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws { throw CloudError.message(L("\(account.cloud.title) no permite compartir con personas desde iCloudy.")) }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws { throw CloudError.message(L("\(account.cloud.title) no permite compartir con personas desde iCloudy.")) }
    func publicLinks(for file: CloudFile) async throws -> [PublicLink] { throw CloudError.message(L("\(account.cloud.title) no gestiona enlaces públicos desde iCloudy.")) }
    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink { throw CloudError.message(L("\(account.cloud.title) no gestiona enlaces públicos desde iCloudy.")) }
    func revokePublicLink(_ link: PublicLink) async throws { throw CloudError.message(L("\(account.cloud.title) no gestiona enlaces públicos desde iCloudy.")) }
    func allPublicLinks() async throws -> [PublicLink] { throw CloudError.message(L("\(account.cloud.title) no permite listar todos sus enlaces públicos.")) }
    func canResumeWithoutSource(_ checkpoint: UploadCheckpoint?) -> Bool { false }
    func rootID() async throws -> String { account.cloud.rootAlias }
    func availableDrives() async throws -> [RemoteDrive] { throw CloudError.message(L("\(account.cloud.title) no tiene unidades compartidas.")) }
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State { throw CloudError.message(L("Este proveedor no usa copias asíncronas.")) }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await downloadHTTP(contentRequest(for: file, exportMime: exportMime), to: destination, maxBytes: maxBytes, progress: progress)
    }
    func resumeCommittedUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt? { nil }
    func currentMetadata(of file: CloudFile) async throws -> CloudFile? { nil }
    func canVerifyDownload(of file: CloudFile) -> Bool { true }
    func downloadChecksum(of file: CloudFile) async throws -> ContentHash? { nil }
    func verifiableChecksum(of file: CloudFile) -> ContentHash? { file.checksum }
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async {
        for url in urls where url.scheme == "https" {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            _ = try? await session.data(for: request, delegate: RedirectGuard.shared)
        }
    }
}
