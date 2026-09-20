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
    func publicLink(for file: CloudFile) async throws -> URL
    func searchPage(term: String, cursor: String?, filters: SearchFilters, referenceDate: Date) async throws -> SearchPage
    func folderTrail(id: String) async throws -> [CloudFile]
    func storageQuota() async throws -> StorageQuota
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange
    func rootID() async throws -> String
    func availableDrives() async throws -> [RemoteDrive]
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async
    var requiresVerifiedLegacyCheckpoint: Bool { get }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt
    func resumeCommittedUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt?
}

extension CloudProvider {
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        RemoteIdentityChange(oldID: file.id, newID: file.id, name: name, descendants: file.isFolder)
    }
    var requiresVerifiedLegacyCheckpoint: Bool { false }
    func rootID() async throws -> String { account.cloud.rootAlias }
    func availableDrives() async throws -> [RemoteDrive] { throw CloudError.message(L("\(account.cloud.title) no tiene unidades compartidas.")) }
    func remoteCopyStatus(_ url: URL) async throws -> RemoteCopy.State { throw CloudError.message(L("Este proveedor no usa copias asíncronas.")) }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await downloadHTTP(contentRequest(for: file, exportMime: exportMime), to: destination, maxBytes: maxBytes, progress: progress)
    }
    func resumeCommittedUpload(local: URL, parent: String, name: String, replacing: String?, checkpoint: UploadCheckpoint?, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt? { nil }
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async {
        for url in urls where url.scheme == "https" {
            var request = URLRequest(url: url)
            request.httpMethod = "DELETE"
            _ = try? await session.data(for: request, delegate: RedirectGuard.shared)
        }
    }
}
