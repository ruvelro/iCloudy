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
    func verifiableChecksum(of file: CloudFile) -> ContentHash? { file.checksum }
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async {
        for url in urls where url.scheme == "https" {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            _ = try? await session.data(for: request, delegate: RedirectGuard.shared)
        }
    }
}
