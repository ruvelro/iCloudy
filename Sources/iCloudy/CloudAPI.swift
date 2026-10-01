import Foundation

/// Application-facing facade. Provider selection happens once, when the account client is created.
@MainActor
final class CloudAPI {
    let provider: any CloudProvider
    let demo: DemoStore?
    var account: Account { provider.account }
    var session: URLSession { provider.session }
    var sessionExpired: Bool { provider.sessionExpired }
    var invalidated: Bool { provider.invalidated }
    var sessionDidExpire: ((String?) -> Void)? {
        get { provider.sessionDidExpire }
        set { provider.sessionDidExpire = newValue }
    }
    var bookmarkDidRenew: ((Data) -> Void)? {
        get { provider.bookmarkDidRenew }
        set { provider.bookmarkDidRenew = newValue }
    }
    var credentialSaveDidFail: ((String) -> Void)? {
        get { provider.credentialSaveDidFail }
        set { provider.credentialSaveDidFail = newValue }
    }
    init(account: Account, session: URLSession = .shared, demo: DemoStore? = nil, tokenProvider: (() async throws -> String)? = nil, credentials: CredentialStore = KeychainCredentialStore()) {
        self.demo = demo
        provider = CloudProviderFactory.make(account: account, session: session, tokenProvider: tokenProvider, credentials: credentials)
    }
    func canResumeWithoutSource(_ checkpoint: UploadCheckpoint?) -> Bool { demo == nil && provider.canResumeWithoutSource(checkpoint) }
    func dropCaches() { provider.dropCaches() }
    func invalidate() { provider.invalidate() }
    func token(force: Bool = false) async throws -> String { try await provider.token(force: force) }
    func send(_ request: inout URLRequest) async throws -> (Data, URLResponse) { try await provider.send(&request) }
    func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] { try await provider.json(url, method: method, body: body) }
    func rootID() async throws -> String {
        if demo != nil { return "root" }
        return try await provider.rootID()
    }
    func availableDrives() async throws -> [RemoteDrive] { try await provider.availableDrives() }
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State { try await provider.remoteCopyStatus(url) }
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async { await provider.abandonUploadSessions(urls: urls, boxSessions: boxSessions) }
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        if let demo { return try demo.list(parent) }
        return try await provider.list(parent: parent, onPage: onPage)
    }
    func createFolder(name: String, parent: String) async throws -> String {
        if let demo { return try demo.add(name: name, parent: parent, folder: true) }
        return try await provider.createFolder(name: name, parent: parent)
    }
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        return try await provider.contentRequest(for: file, exportMime: exportMime)
    }
    func rename(file: CloudFile, name: String) async throws {
        if let demo {
            try demo.rename(file.id, name: name)
            return
        }
        return try await provider.rename(file: file, name: name)
    }
    func move(file: CloudFile, to destination: String) async throws {
        if let demo {
            try demo.move(file.id, to: destination)
            return
        }
        return try await provider.move(file: file, to: destination)
    }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        if let demo {
            _ = try demo.copy(file.id, to: destination)
            return
        }
        return try await provider.copy(file: file, to: destination, accepted: accepted)
    }
    func trash(file: CloudFile) async throws {
        if let demo {
            try demo.trash(file.id)
            return
        }
        return try await provider.trash(file: file)
    }
    func restore(file: CloudFile) async throws {
        if let demo {
            try demo.restore(file.id)
            return
        }
        return try await provider.restore(file: file)
    }
    func deletePermanently(file: CloudFile) async throws {
        if let demo {
            try demo.deletePermanently(file.id)
            return
        }
        return try await provider.deletePermanently(file: file)
    }
    func emptyTrash() async throws {
        if let demo {
            try demo.emptyTrash()
            return
        }
        return try await provider.emptyTrash()
    }
    func publicLink(for file: CloudFile) async throws -> URL {
        if let demo { return try demo.publicLink(file.id) }
        return try await provider.publicLink(for: file)
    }
    func permissions(for file: CloudFile) async throws -> [SharePermission] {
        if let demo { return try demo.permissions(file.id) }
        return try await provider.permissions(for: file)
    }
    func share(file: CloudFile, with recipient: String, role: ShareRole) async throws {
        if let demo { try demo.share(file.id, with: recipient, role: role); return }
        try await provider.share(file: file, with: recipient, role: role)
    }
    func revoke(_ permission: SharePermission, from file: CloudFile) async throws {
        if let demo { try demo.revoke(permission.id, from: file.id); return }
        try await provider.revoke(permission, from: file)
    }
    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        if let demo { return try demo.searchPage(term: term, cursor: cursor, accountID: account.id) }
        return try await provider.searchPage(term: term, cursor: cursor, filters: filters, referenceDate: referenceDate)
    }
    func folderTrail(id: String) async throws -> [CloudFile] {
        if let demo { return try demo.folderTrail(id: id) }
        return try await provider.folderTrail(id: id)
    }
    func storageQuota() async throws -> StorageQuota {
        if let demo { return try demo.storageQuota() }
        return try await provider.storageQuota()
    }
    /// Every download ends checked against the listed size and, when `checksum` allows it and the provider listed
    /// one, its checksum. A copy that fails the check is deleted before the error reaches the caller.
    @discardableResult
    func download(file: CloudFile, to destination: URL, exportMime: String? = nil, maxBytes: Int64? = nil, checksum: Bool = true,
                  progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws -> DownloadVerification {
        // An earlier version, handed over by the versions sheet to the same preview and queue as any other file.
        if demo == nil, let reference = VersionedFile.reference(file) {
            return try await downloadVersion(file, reference: reference, to: destination, exportMime: exportMime, maxBytes: maxBytes, checksum: checksum, progress: progress)
        }
        if let demo {
            try await demo.download(file, to: destination, maxBytes: maxBytes, progress: progress)
        } else {
            try await provider.download(file: file, to: destination, exportMime: exportMime, maxBytes: maxBytes, progress: progress)
            if let maxBytes, Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > maxBytes {
                try? FileManager.default.removeItem(at: destination)
                throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
            }
        }
        return try await verifyDownload(file, at: destination, exported: exportMime != nil, checksum: checksum)
    }
}
