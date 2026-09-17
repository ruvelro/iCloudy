import Foundation

/// O2 Cloud, the storage that comes with an O2 line in Spain and Germany. Under the brand it is Funambol
/// OneMediaHub, whose API O2 neither documents nor promises to keep: what iCloudy speaks is the protocol its own web
/// client uses. That is why the provider is marked experimental, like Mega.
///
/// Two things shape the code. Folders and files live in separate numbering spaces, so a folder 12 and a file 12 are
/// different things; iCloudy prefixes every identifier to keep them apart. And each file has a media type, picture,
/// video, audio or file, which decides the endpoint that renames or deletes it.
final class O2Session {
    let host: String
    /// Sent with every request beside the session cookie. The server rotates it and says so with SEC-1003.
    var validationKey: String
    /// The cookies the web sign-in produced. They are sent as a header rather than left to URLSession's own jar, so
    /// the session belongs to this account alone and never leaks into another provider's requests. That also means
    /// following `Set-Cookie` by hand, which matters: this is how the server renews the session.
    private(set) var cookies: [HTTPCookie]
    /// The browser identity the session was granted to. A session handed to one client and then used by another that
    /// introduces itself differently is a thing servers reject, so iCloudy keeps presenting the same one.
    let userAgent: String?
    /// Set when the server renewed something, so the caller knows the Keychain copy is behind.
    var renewed = false
    var rootFolder: String?
    init(host: String, validationKey: String, cookies: [HTTPCookie] = [], userAgent: String? = nil) {
        self.host = host; self.validationKey = validationKey; self.cookies = cookies; self.userAgent = userAgent
    }
    /// Headers every request to this server carries, whatever it is asking for.
    func apply(to request: inout URLRequest) {
        // The platform checks the referer on every call; without it the request is refused as cross-site.
        request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        if let userAgent { request.setValue(userAgent, forHTTPHeaderField: "User-Agent") }
        request.httpShouldHandleCookies = false
        if let cookieHeader { request.setValue(cookieHeader, forHTTPHeaderField: "Cookie") }
    }
    /// Takes in whatever the server just set. The platform renews the key through the cookie rather than through the
    /// body, so ignoring this is what made sessions die after a few minutes of use.
    func absorb(_ fresh: [HTTPCookie]) {
        guard !fresh.isEmpty else { return }
        var merged = cookies
        for cookie in fresh {
            // A server clears a cookie by sending it back empty or already expired. Storing that over a good value
            // would send an empty session on the next call, which looks exactly like an expired account.
            let cleared = cookie.value.isEmpty || (cookie.expiresDate.map { $0 < Date() } ?? false)
            guard !cleared else { continue }
            guard merged.first(where: { $0.name == cookie.name })?.value != cookie.value else { continue }
            merged.removeAll { $0.name == cookie.name }
            merged.append(cookie)
            renewed = true
            if cookie.name == "validationKey", cookie.value != validationKey { validationKey = cookie.value }
        }
        cookies = merged
    }
    var cookieHeader: String? {
        guard !cookies.isEmpty else { return nil }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Which endpoint a file is renamed or deleted through.
enum O2MediaKind: String {
    case picture, video, audio, file
    /// The server names the property itself, but neither it nor the content type can be requested as fields, so a
    /// listing may carry neither. The name then decides, which is enough because the four kinds map onto media types.
    static func of(_ values: [String: Any], name: String = "") -> O2MediaKind {
        if let named = (values["mediatype"] as? String).flatMap(O2MediaKind.init(rawValue:)) { return named }
        var type = (values["contenttype"] as? String ?? "").lowercased()
        if type.isEmpty, !name.isEmpty { type = CloudAPI.mime(forName: name).lowercased() }
        if type.hasPrefix("image/") { return .picture }
        if type.hasPrefix("video/") { return .video }
        if type.hasPrefix("audio/") { return .audio }
        return .file
    }
}

extension CloudAPI {
    // MARK: - Identifiers

    /// Folders and files are numbered separately, so the kind travels inside the identifier.
    nonisolated static func o2FolderID(_ id: String) -> String { "f:" + id }
    nonisolated static func o2MediaID(_ id: String, kind: O2MediaKind) -> String { "m:\(kind.rawValue):\(id)" }
    /// Reads one back. A folder gives a nil kind.
    nonisolated static func o2Split(_ id: String) -> (value: String, kind: O2MediaKind?)? {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        if parts.count == 2, parts[0] == "f" { return (parts[1], nil) }
        if parts.count == 3, parts[0] == "m", let kind = O2MediaKind(rawValue: parts[1]) { return (parts[2], kind) }
        return nil
    }
    private func o2Folder(_ id: String) async throws -> String {
        if id == "root" { return try await o2Root() }
        guard let parsed = Self.o2Split(id), parsed.kind == nil else {
            throw CloudError.message(L("Ese destino no es una carpeta de O2 Cloud."))
        }
        return parsed.value
    }
    private func o2Media(_ file: CloudFile) throws -> (value: String, kind: O2MediaKind) {
        guard let parsed = Self.o2Split(file.id), let kind = parsed.kind else {
            throw CloudError.message(L("Ese elemento de O2 Cloud no es un archivo."))
        }
        return (parsed.value, kind)
    }

    // MARK: - Session

    var o2Host: String { account.options["host"] ?? "cloud.o2online.es" }

    /// Restores the session obtained through O2's own sign-in pages. There is no password to replay and no token to
    /// refresh: when the session goes, the only way back is signing in again.
    func o2Session() throws -> O2Session {
        guard !invalidated else { throw CancellationError() }
        if let o2SessionCache { return o2SessionCache }
        guard let credential = try credentials.read(account.credentialKey),
              let restored = O2API.restore(credential.secret) else {
            throw CloudError.sessionExpired(L("La sesión de O2 Cloud ha caducado. Vuelve a iniciar sesión."))
        }
        let state = O2Session(host: o2Host, validationKey: restored.validationKey, cookies: restored.cookies,
                              userAgent: restored.userAgent)
        o2SessionCache = state
        return state
    }

    /// One SAPI call. `body` is sent as JSON when present, which is what the web client does for everything but login.
    @discardableResult
    func o2Call(_ path: String, action: String, query: [URLQueryItem] = [], body: [String: Any]? = nil,
                method: String? = nil, retrying: Bool = true) async throws -> [String: Any] {
        let state = try o2Session()
        do {
            let answer = try await O2API.call(path, action: action, query: query, body: body, method: method,
                                              state: state, session: session)
            o2Persist(state)
            return answer
        } catch let error as O2API.Failure where error.code == "SEC-1003" && retrying {
            // The key rotates while the session lives on, and the replacement comes inside the error itself.
            guard let fresh = error.data, !fresh.isEmpty else {
                expireSession()
                throw CloudError.sessionExpired(L("La sesión de O2 Cloud ha caducado (SEC-1003 en \(error.origin ?? "?")). Vuelve a iniciar sesión."))
            }
            state.validationKey = fresh
            state.renewed = true
            o2Persist(state)
            return try await o2Call(path, action: action, query: query, body: body, method: method, retrying: false)
        } catch let error as O2API.Failure where error.isExpiredSession {
            expireSession()
            throw CloudError.sessionExpired(L("La sesión de O2 Cloud ha caducado (\(error.code) en \(error.origin ?? "?")). Vuelve a iniciar sesión."))
        }
    }

    /// Writes a renewed session back to the Keychain. Without this the next launch would start from a key the
    /// server had already replaced, and the account would look expired before doing anything.
    func o2Persist(_ state: O2Session) {
        guard state.renewed else { return }
        state.renewed = false
        guard var credential = try? credentials.read(account.credentialKey) else { return }
        credential.secret = O2API.store(validationKey: state.validationKey, cookies: state.cookies,
                                        userAgent: state.userAgent)
        try? credentials.save(credential, key: account.credentialKey)
    }

    func o2Root() async throws -> String {
        let state = try o2Session()
        if let cached = state.rootFolder { return cached }
        let answer = try await o2Call("media/folder", action: "get", query: [URLQueryItem(name: "limit", value: "1")])
        guard let folders = answer["folders"] as? [[String: Any]], let id = O2API.identifier(folders.first?["id"]) else {
            throw CloudError.message(L("O2 Cloud no devolvió la carpeta raíz de la cuenta."))
        }
        state.rootFolder = id
        return id
    }

    // MARK: - Browsing

    func o2List(parent: String) async throws -> [CloudFile] {
        let folder = try await o2Folder(parent)
        var files: [CloudFile] = []

        // Folders and files come from different endpoints, each paged on its own.
        var offset = 0
        while true {
            let page = try await o2Call("media/folder", action: "list", query: [
                URLQueryItem(name: "parentid", value: folder),
                URLQueryItem(name: "limit", value: String(O2API.pageSize))] + O2API.skip(offset), method: "GET")
            let batch = page["folders"] as? [[String: Any]] ?? []
            files.append(contentsOf: batch.compactMap(Self.o2FolderFile))
            guard batch.count == O2API.pageSize else { break }
            offset += batch.count
            try Task.checkCancellation()
        }

        offset = 0
        while true {
            let page = try await o2Call("media", action: "get", query: [
                URLQueryItem(name: "folderid", value: folder),
                URLQueryItem(name: "limit", value: String(O2API.pageSize))] + O2API.skip(offset),
                body: ["data": ["fields": O2API.mediaFields]])
            let batch = page["media"] as? [[String: Any]] ?? []
            files.append(contentsOf: batch.compactMap(Self.o2MediaFile))
            guard page["more"] as? Bool == true, !batch.isEmpty else { break }
            offset += batch.count
            try Task.checkCancellation()
        }
        return Self.sorted(files)
    }
    nonisolated static func o2FolderFile(_ values: [String: Any]) -> CloudFile? {
        guard let id = O2API.identifier(values["id"]), let name = values["name"] as? String else { return nil }
        return CloudFile(id: o2FolderID(id), name: name, mime: "application/vnd.google-apps.folder", size: nil,
                         modified: O2API.date(values["modificationdate"]), webURL: nil, isFolder: true)
    }
    nonisolated static func o2MediaFile(_ values: [String: Any]) -> CloudFile? {
        guard let id = O2API.identifier(values["id"]), let name = values["name"] as? String else { return nil }
        let size = O2API.number(values["size"])
        return CloudFile(id: o2MediaID(id, kind: O2MediaKind.of(values, name: name)), name: name,
                         mime: values["contenttype"] as? String ?? mime(forName: name),
                         size: size, modified: O2API.date(values["modificationdate"]),
                         webURL: (values["viewurl"] as? String).flatMap(URL.init(string:)), isFolder: false)
    }

    /// Walks up from a folder to the root. Funambol gives a folder its parent, so this is one request per level.
    func o2Trail(id: String) async throws -> [CloudFile] {
        let root = try await o2Root()
        var current = try await o2Folder(id)
        var trail: [CloudFile] = []
        while current != root, trail.count < 64 {
            let answer = try await o2Call("media/folder", action: "get",
                                          query: [URLQueryItem(name: "id", value: current)], method: "GET")
            guard let values = (answer["folders"] as? [[String: Any]])?.first ?? answer["folder"] as? [String: Any],
                  let file = Self.o2FolderFile(values) else { break }
            trail.append(file)
            guard let parent = O2API.identifier(values["parentid"]), parent != current else { break }
            current = parent
        }
        return trail.reversed()
    }

    func o2Quota() async throws -> StorageQuota {
        let answer = try await o2Call("media", action: "get-storage-space",
                                      query: [URLQueryItem(name: "softdeleted", value: "true")], method: "GET")
        let used = O2API.number(answer["used"]) ?? 0
        let unlimited = answer["nolimit"] as? Bool ?? (answer["nolimit"] as? String == "true")
        let quota = O2API.number(answer["quota"])
        return StorageQuota(used: used, total: unlimited ? nil : quota)
    }

    // MARK: - Changing things

    func o2CreateFolder(name: String, parent: String) async throws -> String {
        let answer = try await o2Call("media/folder", action: "save",
                                      body: ["data": ["magic": false, "offline": false, "name": name,
                                                      "parentid": try await o2Folder(parent)]])
        guard let id = O2API.identifier(answer["id"]) ?? O2API.identifier((answer["folder"] as? [String: Any])?["id"]) else {
            throw CloudError.message(L("O2 Cloud no devolvió la carpeta creada."))
        }
        return Self.o2FolderID(id)
    }
    func o2Rename(file: CloudFile, name: String) async throws {
        if file.isFolder {
            let id = try await o2Folder(file.id)
            try await o2Call("media/folder", action: "save", body: ["data": ["id": id, "name": name]])
        } else {
            let media = try o2Media(file)
            try await o2Call("upload/" + media.kind.rawValue, action: "save-metadata",
                             body: ["data": ["id": media.value, "name": name]])
        }
    }
    func o2Move(file: CloudFile, to destination: String) async throws {
        let target = try await o2Folder(destination)
        if file.isFolder {
            let id = try await o2Folder(file.id)
            // The name goes along because this endpoint saves the folder rather than patching one field.
            try await o2Call("media/folder", action: "save",
                             body: ["data": ["id": id, "parentid": target, "name": file.name]])
        } else {
            let media = try o2Media(file)
            try await o2Call("upload/" + media.kind.rawValue, action: "save-metadata",
                             body: ["data": ["id": media.value, "folderid": target]])
        }
    }
    /// Deleting is a soft delete, so the item lands in O2's own bin and can be restored from its web interface.
    func o2Trash(file: CloudFile) async throws {
        if file.isFolder {
            let id = try await o2Folder(file.id)
            try await o2Call("media/folder", action: "softdelete", body: ["data": ["folders": [id]]])
        } else {
            let media = try o2Media(file)
            try await o2Call("media/" + media.kind.rawValue, action: "delete",
                             query: [URLQueryItem(name: "softdelete", value: "true")],
                             body: ["data": [media.kind.rawValue + "s": [media.value]]])
        }
    }
    /// O2 shares folders through a link of its own. Single files go through its web interface, which builds a
    /// shared set first, so iCloudy says so instead of guessing at a two-step flow it cannot verify.
    func o2PublicLink(for file: CloudFile) async throws -> URL {
        guard file.isFolder else {
            throw CloudError.message(L("O2 Cloud crea enlaces de carpetas. Para un archivo suelto, compártelo desde su web."))
        }
        let answer = try await o2Call("link/folder", action: "save",
                                      body: ["data": ["folderid": try await o2Folder(file.id)]])
        // The field has changed name between versions of the platform, so every plausible one is accepted.
        for key in ["url", "link", "shorturl", "shortUrl", "publicurl"] {
            if let text = answer[key] as? String, let url = URL(string: text) { return url }
        }
        if let token = (answer["key"] as? String) ?? (answer["token"] as? String) ?? O2API.identifier(answer["id"]),
           let url = URL(string: "https://\(o2Host)/link/\(token)") {
            return url
        }
        throw CloudError.message(L("O2 Cloud no devolvió el enlace de la carpeta."))
    }

    // MARK: - Contents

    func o2Download(file: CloudFile, to destination: URL, progress: @escaping (Int64, Int64) -> Void) async throws {
        let media = try o2Media(file)
        let answer = try await o2Call("media", action: "get",
                                      body: ["data": ["ids": [media.value], "fields": ["url", "name", "size"]]])
        // Its own clients are served over TLS, so an address that arrives without it is upgraded rather than
        // attempted in the clear, which macOS would refuse anyway.
        guard let entry = (answer["media"] as? [[String: Any]])?.first,
              let address = entry["url"] as? String, let url = CloudAPI.secureURL(address) else {
            throw CloudError.message(L("O2 Cloud no devolvió la dirección de descarga."))
        }
        var request = URLRequest(url: url)
        // The temporary address is still behind the session, so it needs the same identity and cookies.
        try o2Session().apply(to: &request)
        let (temporary, response) = try await session.download(for: request)
        try HTTP.validate(response, data: Data())
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
        let written = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        progress(written, max(written, file.size ?? written))
    }

    /// One multipart request, which is all the platform offers third parties: there is no resumable upload, so a
    /// restart begins again. The envelope is built on disk so a large file never sits in memory.
    func o2Upload(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint,
                  save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        let state = try o2Session()
        let folder = try await o2Folder(parent)
        let total = cursor.total
        cursor.offset = 0; cursor.url = nil; try save(cursor)

        let boundary = "iCloudy-" + UUID().uuidString
        let metadata: [String: Any] = ["data": ["name": name, "size": total, "folderid": folder,
                                                "contenttype": Self.mime(forName: name),
                                                "modificationdate": O2API.stamp(cursor.modified ?? Date())]]
        let envelope = try await Self.o2Envelope(local: local, name: name, boundary: boundary, metadata: metadata)
        defer { try? FileManager.default.removeItem(at: envelope) }

        var request = URLRequest(url: O2API.url(host: o2Host, path: "upload", action: "save", state: state, query: [
            URLQueryItem(name: "acceptasynchronous", value: "true")]))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        state.apply(to: &request)
        let reporter = O2UploadReporter(total: total, progress: progress)
        let (data, response) = try await session.upload(for: request, fromFile: envelope, delegate: reporter)
        try HTTP.validate(response, data: data)
        let answer = try O2API.payload(data)

        cursor.offset = total; cursor.complete = true; try save(cursor); progress(total, total)
        // Replacing means uploading beside the old copy and then binning it: the platform has no overwrite.
        if let replacing, let previous = Self.o2Split(replacing), previous.kind != nil {
            let old = CloudFile(id: replacing, name: name, mime: "", size: nil, modified: nil, webURL: nil, isFolder: false)
            try? await o2Trash(file: old)
        }
        let id = O2API.identifier(answer["id"]) ?? O2API.identifier((answer["media"] as? [[String: Any]])?.first?["id"])
        // The platform reports no checksum, so there is nothing to compare the upload against.
        return UploadReceipt(remoteID: id.map { Self.o2MediaID($0, kind: O2MediaKind.of([:], name: name)) },
                             verification: .unavailable)
    }
    /// Writes the multipart body to a temporary file, copying the source in blocks.
    nonisolated static func o2Envelope(local: URL, name: String, boundary: String, metadata: [String: Any]) async throws -> URL {
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("o2-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: target.path, contents: nil) else {
            throw CloudError.message(L("No se pudo preparar la subida."))
        }
        let output = try FileHandle(forWritingTo: target)
        defer { try? output.close() }
        let json = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        var header = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"\r\nContent-Type: application/json\r\n\r\n".utf8)
        header.append(json)
        // A quotation mark in the name would end the header early, so it is the one character replaced.
        let safe = name.replacingOccurrences(of: "\"", with: "'")
        header.append(Data("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safe)\"\r\nContent-Type: \(mime(forName: name))\r\n\r\n".utf8))
        try output.write(contentsOf: header)

        let input = try FileHandle(forReadingFrom: local)
        defer { try? input.close() }
        while true {
            try Task.checkCancellation()
            let chunk = try await blockingIO { try input.read(upToCount: 4 * 1024 * 1024) ?? Data() }
            if chunk.isEmpty { break }
            try await blockingIO { try output.write(contentsOf: chunk) }
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return target
    }
}

/// Reports how much of the upload has left this Mac. Funambol offers no resumable protocol, so this is the only
/// progress there is.
final class O2UploadReporter: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let total: Int64
    private let progress: (Int64, Int64) -> Void
    init(total: Int64, progress: @escaping (Int64, Int64) -> Void) { self.total = total; self.progress = progress }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let sent = min(totalBytesSent, total)
        let report = progress
        Task { @MainActor in report(sent, max(self.total, sent)) }
    }
}
