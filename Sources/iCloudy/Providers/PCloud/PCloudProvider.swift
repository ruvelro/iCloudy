import Foundation

/// pCloud through its JSON API. Every method is a path on the account's regional host, takes its arguments as
/// parameters and answers HTTP 200 with a `result` code, so success is read from the body rather than the status.
/// Items are addressed by folderid and fileid, which stay the same across renames and moves.
@MainActor
final class PCloudProvider: CloudSession, CloudProvider {

}

extension PCloudProvider {
    var apiHost: String { PCloudRegion.host(for: account) }

    /// Parameters are encoded the way `HTTP.form` does it, which escapes `+`: `URLQueryItem` leaves it as is, and a
    /// server reading it as a space would rename "a+b.txt" to "a b.txt".
    func pcloudURL(_ method: String, _ parameters: [String: String] = [:]) -> URL {
        var components = URLComponents()
        components.scheme = "https"; components.host = apiHost; components.path = "/" + method
        if !parameters.isEmpty { components.percentEncodedQuery = String(decoding: HTTP.form(parameters), as: UTF8.self) }
        return components.url!
    }

    /// Reads `result` from an answer. A refused token marks the account as expired here, because pCloud never says so
    /// with a 401 and the shared session code would not notice.
    func pcloudCheck(_ data: Data, _ response: URLResponse) throws -> [String: Any] {
        try HTTP.validate(response, data: data)
        do { return try PCloudError.check(try HTTP.json(data)) }
        catch let error as CloudError where error.isSessionExpired {
            if case .sessionExpired(let reason) = error { expireSession(reason) }
            throw error
        }
    }

    /// Calls one method. Reads go as GET and are repeated when pCloud reports a failure of its own or a rate limit;
    /// writes go as a form POST and are never repeated, since the server may have acted before failing.
    func pcloud(_ method: String, _ parameters: [String: String] = [:], write: Bool = false) async throws -> [String: Any] {
        var request: URLRequest
        if write {
            request = try await self.request(pcloudURL(method), method: "POST")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = HTTP.form(parameters)
        } else {
            request = try await self.request(pcloudURL(method, parameters))
        }
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await send(&request)
            if attempt < 3, let delay = Self.retryDelay(response, method: request.httpMethod ?? "GET", attempt: attempt) {
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            do { return try pcloudCheck(data, response) }
            catch let error as ServiceError where !write && error.retryable && attempt < 3 {
                try await Task.sleep(for: .seconds(min(max(1, error.retryAfter ?? pow(2, Double(attempt))), 30)))
            }
        }
        throw CloudError.message(L("El servicio no responde."))
    }

    func pcloudList(parent: String) async throws -> [CloudFile] {
        // The trash is a tree of its own whose top is folder 0 of `trash_list`.
        let body = parent == Collection.trash.rootID
            ? try await pcloud("trash_list", ["folderid": "0", "timeformat": "timestamp"])
            : try await pcloud("listfolder", ["folderid": Self.folderID(parent), "timeformat": "timestamp"])
        let contents = (body["metadata"] as? [String: Any])?["contents"] as? [[String: Any]] ?? []
        return Self.sorted(contents.compactMap(Self.pcloudFile))
    }

    /// Moving and renaming are the same call: `toname` renames, `tofolderid` moves and keeps the name.
    func pcloudRename(_ file: CloudFile, _ changes: [String: String]) async throws {
        _ = try await pcloud(file.isFolder ? "renamefolder" : "renamefile", Self.itemParameter(file).merging(changes) { _, new in new }, write: true)
    }

    /// `noover` makes a name already taken in the destination a refusal instead of an overwrite.
    func pcloudCopy(_ file: CloudFile, to destination: String) async throws {
        var parameters = Self.itemParameter(file)
        parameters["tofolderid"] = Self.folderID(destination); parameters["noover"] = "1"
        _ = try await pcloud(file.isFolder ? "copyfolder" : "copyfile", parameters, write: true)
    }

    /// Both deletions land in pCloud's trash, a folder with everything below it.
    func pcloudTrash(_ file: CloudFile) async throws {
        _ = try await pcloud(file.isFolder ? "deletefolderrecursive" : "deletefile", Self.itemParameter(file), write: true)
    }

    /// Only what sits in the trash can be cleared, so an item still in the tree is binned first. Whether it is there
    /// cannot be read from its id; binning one that already is answers "not found", which is the same thing.
    func pcloudDeletePermanently(_ file: CloudFile) async throws {
        do { try await pcloudTrash(file) }
        catch let error as ServiceError where error.status == 404 {}
        _ = try await pcloud("trash_clear", Self.itemParameter(file), write: true)
    }

    func pcloudTrail(id: String) async throws -> [CloudFile] {
        var trail: [CloudFile] = []
        var current = Self.folderID(id)
        // Each step costs a request; the cap keeps a cycle in a broken answer from running forever.
        for _ in 0..<64 where current != "0" {
            let body = try await pcloud("listfolder", ["folderid": current, "nofiles": "1", "timeformat": "timestamp"])
            guard let metadata = body["metadata"] as? [String: Any], let folder = Self.pcloudFile(metadata) else { break }
            trail.insert(folder, at: 0)
            current = (metadata["parentfolderid"] as? NSNumber)?.stringValue ?? "0"
        }
        return trail
    }

    func pcloudQuota() async throws -> StorageQuota {
        let body = try await pcloud("userinfo")
        guard let used = (body["usedquota"] as? NSNumber)?.int64Value else { throw CloudError.message(L("El proveedor no ha informado del espacio utilizado.")) }
        let total = (body["quota"] as? NSNumber)?.int64Value
        return StorageQuota(used: used, total: (total ?? 0) > 0 ? total : nil)
    }

    /// The content lives on a separate storage host, behind a link pCloud signs for this address and for a limited
    /// time. The link is the credential, so the token is not sent along with it.
    func pcloudContentRequest(for file: CloudFile) async throws -> URLRequest {
        let body = try await pcloud("getfilelink", ["fileid": Self.numericID(file.id)])
        guard let host = (body["hosts"] as? [String])?.first(where: { !$0.isEmpty }), let path = body["path"] as? String else {
            throw CloudError.message(L("pCloud no devolvió el enlace de descarga."))
        }
        // The path usually arrives already escaped; one that is not is escaped here rather than refused.
        let target = path.hasPrefix("/") ? path : "/" + path
        var components = URLComponents()
        components.scheme = "https"; components.host = host; components.path = target
        guard let url = URL(string: "https://" + host + target) ?? components.url, url.host == host else {
            throw CloudError.message(L("pCloud no devolvió el enlace de descarga."))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        return request
    }

    /// The file as it is now, with the digest pCloud computes for it. Folders have no digest and no cheap description.
    func pcloudChecksum(of file: CloudFile) async throws -> (file: CloudFile?, checksum: ContentHash?) {
        let body = try await pcloud("checksumfile", ["fileid": Self.numericID(file.id), "timeformat": "timestamp"])
        let checksum = Self.pcloudChecksum(body)
        var current = (body["metadata"] as? [String: Any]).flatMap(Self.pcloudFile)
        current?.checksum = checksum
        return (current, checksum)
    }
}

/// Public links. pCloud keeps one list of them for the whole account and makes a new link every time it is asked,
/// so an existing link to the same item is handed back instead of piling up links that each need revoking.
struct PCloudPublicLink: Equatable {
    let id: String
    let url: URL
    /// The linked item, in iCloudy's notation ("d…" or "f…").
    let itemID: String
}

extension PCloudProvider {
    func pcloudPublicLinks() async throws -> [PCloudPublicLink] {
        let body = try await pcloud("listpublinks")
        return (body["publinks"] as? [[String: Any]] ?? []).compactMap { value in
            guard let id = (value["linkid"] as? NSNumber)?.stringValue, let url = (value["link"] as? String).flatMap(URL.init(string:)),
                  let item = (value["metadata"] as? [String: Any])?["id"] as? String else { return nil }
            return PCloudPublicLink(id: id, url: url, itemID: item)
        }
    }
    func pcloudPublicLink(for file: CloudFile) async throws -> URL {
        if let existing = try await pcloudPublicLinks().first(where: { $0.itemID == file.id }) { return existing.url }
        let body = try await pcloud(file.isFolder ? "getfolderpublink" : "getfilepublink", Self.itemParameter(file), write: true)
        guard let url = (body["link"] as? String).flatMap(URL.init(string:)) else { throw CloudError.message(L("pCloud no devolvió el enlace.")) }
        return url
    }
    func pcloudDeletePublicLink(_ link: PCloudPublicLink) async throws {
        _ = try await pcloud("deletepublink", ["linkid": link.id], write: true)
    }
}

extension PCloudProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        try await pcloudList(parent: parent)
    }

    func createFolder(name: String, parent: String) async throws -> String {
        let body = try await pcloud("createfolder", ["folderid": Self.folderID(parent), "name": name], write: true)
        guard let id = (body["metadata"] as? [String: Any])?["id"] as? String else { throw CloudError.message(L("No se pudo crear la carpeta.")) }
        return id
    }

    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        try await pcloudContentRequest(for: file)
    }

    func currentMetadata(of file: CloudFile) async throws -> CloudFile? {
        guard !file.isFolder else { return nil }
        return try await pcloudChecksum(of: file).file
    }

    func rename(file: CloudFile, name: String) async throws { try await pcloudRename(file, ["toname": name]) }

    func move(file: CloudFile, to destination: String) async throws { try await pcloudRename(file, ["tofolderid": Self.folderID(destination)]) }

    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        try await pcloudCopy(file, to: destination)
    }

    func trash(file: CloudFile) async throws { try await pcloudTrash(file) }

    /// pCloud puts the item back where it was; when that folder is gone too, the refusal is shown as it comes.
    func restore(file: CloudFile) async throws {
        _ = try await pcloud("trash_restore", Self.itemParameter(file), write: true)
    }

    func deletePermanently(file: CloudFile) async throws { try await pcloudDeletePermanently(file) }

    /// Folder 0 of the trash is the whole trash.
    func emptyTrash() async throws { _ = try await pcloud("trash_clear", ["folderid": "0"], write: true) }

    func publicLink(for file: CloudFile) async throws -> URL { try await pcloudPublicLink(for: file) }

    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        throw CloudError.message(L("pCloud no ofrece búsqueda a otras aplicaciones. Navega por las carpetas o usa el filtro de la carpeta actual."))
    }

    func folderTrail(id: String) async throws -> [CloudFile] { try await pcloudTrail(id: id) }

    func storageQuota() async throws -> StorageQuota { try await pcloudQuota() }

    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try await pcloudUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }

    /// pCloud forgets an abandoned upload by itself after a while; deleting it frees the space it holds sooner.
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async {
        for id in boxSessions { _ = try? await pcloud("upload_delete", ["uploadid": id], write: true) }
    }
}
