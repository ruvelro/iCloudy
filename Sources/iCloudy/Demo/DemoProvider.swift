import Foundation

/// The local demo as a provider like any other. It used to be a second road through `CloudAPI`, with a branch in
/// every method, so the demo exercised none of the code the real providers go through: the upload checkpoints, the
/// download checks, the refusals of what a provider cannot do. Now only the storage is simulated.
@MainActor
final class DemoProvider: CloudSession, CloudProvider {
    let store: DemoStore

    init(account: Account, store: DemoStore) {
        self.store = store
        super.init(account: account, tokenProvider: { "demo" })
    }

    func rootID() async throws -> String { "root" }
    func list(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] { try store.list(parent) }
    func createFolder(name: String, parent: String) async throws -> String { try store.add(name: name, parent: parent, folder: true) }
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        throw CloudError.message(L("La demo no sirve archivos por la red."))
    }
    func rename(file: CloudFile, name: String) async throws { try store.rename(file.id, name: name) }
    func move(file: CloudFile, to destination: String) async throws { try store.move(file.id, to: destination) }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)?) async throws { try store.copy(file.id, to: destination) }
    func trash(file: CloudFile) async throws { try store.trash(file.id) }
    func restore(file: CloudFile) async throws { try store.restore(file.id) }
    func deletePermanently(file: CloudFile) async throws { try store.deletePermanently(file.id) }
    func emptyTrash() async throws { try store.emptyTrash() }
    func publicLink(for file: CloudFile) async throws -> URL { try store.publicLink(file.id) }
    func permissions(for file: CloudFile) async throws -> [SharePermission] { try store.permissions(file.id) }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws { try store.share(file.id, with: recipient, role: role) }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws { try store.revoke(permission.id, from: file.id) }
    func publicLinks(for file: CloudFile) async throws -> [PublicLink] { throw Self.noLinks }
    func createPublicLink(for file: CloudFile, options: PublicLinkOptions) async throws -> PublicLink { throw Self.noLinks }
    func revokePublicLink(_ link: PublicLink) async throws { throw Self.noLinks }
    func allPublicLinks() async throws -> [PublicLink] { throw Self.noLinks }
    private static var noLinks: CloudError { CloudError.message(L("La demo no gestiona enlaces públicos.")) }
    func searchPage(term: String, cursor: String?, filters: SearchFilters, referenceDate: Date) async throws -> SearchPage {
        try store.searchPage(term: term, cursor: cursor, accountID: account.id)
    }
    func folderTrail(id: String) async throws -> [CloudFile] { try store.folderTrail(id: id) }
    func storageQuota() async throws -> StorageQuota { try store.storageQuota() }
    func versions(of file: CloudFile) async throws -> [FileVersion] { throw CloudError.message(account.versionsUnavailable) }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await store.download(file, to: destination, maxBytes: maxBytes, progress: progress)
    }
    func currentMetadata(of file: CloudFile) async throws -> CloudFile? { store.file(file.id) }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                    save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let id = try await store.upload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
        // The bytes were copied on this Mac from the very file that was read: nothing can differ.
        return UploadReceipt(remoteID: id, verification: .verified)
    }
}
