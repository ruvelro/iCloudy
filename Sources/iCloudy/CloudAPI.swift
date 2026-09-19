import Foundation

/// One token refresh at a time per Keychain entry, shared by every client that reads it.
///
/// A shared drive or a document library borrows the credential of the account it came from, so two `CloudAPI`s read
/// and write the same entry. Microsoft rotates the refresh token on every use and retires the previous one, so two
/// clients refreshing at the same moment leave one of them holding a token the provider has already thrown away, and
/// that account goes to "expired" for a reason nobody can see.
@MainActor
enum TokenRefresher {
    private static var inFlight: [String: Task<Credential, Error>] = [:]
    static func refresh(key: String, _ work: @escaping () async throws -> Credential) async throws -> Credential {
        if let running = inFlight[key] { return try await running.value }
        let task = Task { try await work() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }
    /// Only for tests: forgets whatever is in flight so one case cannot wait on another's refresh.
    static func reset() { inFlight.removeAll() }
}

@MainActor
final class CloudAPI {
    let account: Account
    let session: URLSession
    let demo: DemoStore?
    private let tokenProvider: (() async throws -> String)?
    let credentials: CredentialStore
    private(set) var invalidated = false
    /// Set once the provider rejects the stored credential. Only reconnecting the account, which replaces this client, clears it.
    private(set) var sessionExpired = false
    /// Reports that the account needs signing in again, and why when the provider said something useful. The reason
    /// is shown to the user: an undocumented provider that drops sessions is impossible to diagnose from a report
    /// that only says "expired".
    var sessionDidExpire: ((String?) -> Void)?
    /// Reports that a renewed credential could not be written to the Keychain. The session keeps working for this
    /// run, but the next launch will read the retired one, so the person deserves to know before it happens.
    var credentialSaveDidFail: ((String) -> Void)?
    /// Keychain reads are synchronous and comparatively slow; the credential is read once per client and kept current here.
    private var cachedCredential: Credential?
    /// Real id behind the "root" alias, needed where the providers reject the alias (parents, parentReference).
    var rootIDCache: String?
    /// Live FTP control connection, created on first use and reused until the account is disconnected.
    var ftpSession: FTPSession?
    /// Signed-in Mega session and its decrypted tree, kept for as long as this client lives.
    var megaStateCache: MegaState?
    /// Signed-in O2 Cloud session: its validation key and the account's root folder.
    var o2SessionCache: O2Session?
    /// Resolved root of a volume account, with its security scope held open while this client exists.
    var volumeRootCache: URL?
    var volumeScopeOpen = false
    /// Forgets what was fetched from the provider without forgetting the session. "Actualizar" calls this so a
    /// provider that hands out the whole account at once, like Mega, fetches it again instead of answering from memory.
    func dropCaches() {
        megaStateCache?.expire()
        o2SessionCache?.rootFolder = nil
    }
    func invalidate() {
        invalidated = true
        if let ftpSession { Task { await ftpSession.close() } }
        ftpSession = nil
        if volumeScopeOpen, let volumeRootCache { volumeRootCache.stopAccessingSecurityScopedResource() }
        volumeScopeOpen = false; volumeRootCache = nil
        megaStateCache = nil
        o2SessionCache = nil
    }
    init(account: Account, session: URLSession = .shared, demo: DemoStore? = nil, tokenProvider: (() async throws -> String)? = nil, credentials: CredentialStore = KeychainCredentialStore()) {
        self.demo = demo
        self.account = account; self.session = session; self.tokenProvider = tokenProvider; self.credentials = credentials
    }
    func expireSession(_ reason: String? = nil) {
        guard !sessionExpired else { return }
        sessionExpired = true
        sessionDidExpire?(reason)
    }

    /// `force` renews even when the local clock still considers the token valid, e.g. after a 401.
    func token(force: Bool = false) async throws -> String {
        guard !invalidated else { throw CancellationError() }
        if let tokenProvider { return try await tokenProvider() }
        guard !sessionExpired else { throw CloudError.sessionExpired(nil) }
        if cachedCredential == nil { cachedCredential = try credentials.read(account.credentialKey) }
        guard var credential = cachedCredential else { expireSession(); throw CloudError.sessionExpired(nil) }
        if !force, credential.expires.timeIntervalSinceNow > 90 { return credential.accessToken }
        // The cached copy may be older than what another client sharing this entry has already written, and renewing
        // from a refresh token the provider has retired would fail for no reason.
        if let stored = try? credentials.read(account.credentialKey), stored.expires > credential.expires {
            credential = stored; cachedCredential = stored
            if !force, stored.expires.timeIntervalSinceNow > 90 { return stored.accessToken }
        }
        // A self-hosted password has no refresh endpoint: if the server stops accepting it, only new credentials help.
        guard !account.cloud.isSelfHosted else {
            if force { expireSession(); throw CloudError.sessionExpired(nil) }
            return credential.accessToken
        }
        let current = credential
        do {
            let renewed = try await TokenRefresher.refresh(key: account.credentialKey) { [self] in
                try await exchangeRefreshToken(current)
            }
            cachedCredential = renewed
            return renewed.accessToken
        } catch let error as CloudError {
            // The refresh may have been started by another client sharing this entry; this one has to notice too.
            if case .sessionExpired(let reason) = error { expireSession(reason) }
            throw error
        }
    }
    /// Trades the refresh token for a new one. Runs inside `TokenRefresher`, so only one of these is in flight per
    /// Keychain entry however many clients are waiting on it.
    private func exchangeRefreshToken(_ credential: Credential) async throws -> Credential {
        var fields = ["client_id": account.clientID, "refresh_token": credential.refreshToken, "grant_type": "refresh_token"]
        if let secret = account.clientSecret { fields["client_secret"] = secret }
        let result: [String: Any]
        do { result = try await HTTP.token(cloud: account.cloud, values: fields, session: session) }
        catch let error as ServiceError where (400..<500).contains(error.status) && !error.retryable {
            // invalid_grant, revoked consent or a deleted client: retrying cannot fix it, only a new sign-in.
            try Task.checkCancellation()
            throw CloudError.sessionExpired(error.code == nil ? nil : error.detail)
        }
        try Task.checkCancellation()
        guard !invalidated else { throw CancellationError() }
        guard let access = result["access_token"] as? String else { throw CloudError.message(L("No se pudo renovar la sesión. Vuelve a conectar la cuenta.")) }
        let updated = Credential(accessToken: access, refreshToken: result["refresh_token"] as? String ?? credential.refreshToken,
                                 expires: Date().addingTimeInterval(result["expires_in"] as? Double ?? 3600))
        // The provider has retired the old refresh token by now, so this one is the only one that still works. It is
        // adopted before the Keychain write, and a write that fails keeps the session alive for this run instead of
        // throwing away the only token there is.
        cachedCredential = updated
        do { try credentials.save(updated, key: account.credentialKey) }
        catch {
            credentialSaveDidFail?(L("No se pudo guardar la sesión renovada de \(account.cloud.title): \(error.localizedDescription) La cuenta funciona ahora, pero habrá que volver a conectarla al abrir iCloudy de nuevo."))
        }
        return updated
    }

    func request(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue(account.cloud.authorizationScheme + " " + (try await token()), forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends an authenticated request. A first 401 renews the token and retries once; a second 401 means the provider
    /// no longer honours this account, so the session is marked as expired instead of failing silently on every call.
    func send(_ request: inout URLRequest) async throws -> (Data, URLResponse) {
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil else { return (data, response) }
        request.setValue(account.cloud.authorizationScheme + " " + (try await token(force: true)), forHTTPHeaderField: "Authorization")
        let (retriedData, retriedResponse) = try await session.data(for: request)
        if (retriedResponse as? HTTPURLResponse)?.statusCode == 401 { expireSession(); throw CloudError.sessionExpired(nil) }
        return (retriedData, retriedResponse)
    }

    /// How long to wait before repeating a refused request, or nil when it must not be repeated.
    ///
    /// A 429 is the provider saying it did not process the request at all, so repeating it is safe whatever the
    /// method was. A 5xx may have been applied before the failure reached us, so only methods that do the same thing
    /// twice as they do once are repeated; repeating a POST could create a second folder. `repeatable` is for the
    /// calls that are reads despite being POSTs, which is most of Dropbox's API.
    static func retryDelay(_ response: URLResponse?, method: String, attempt: Int, repeatable: Bool = false) -> Double? {
        guard let http = response as? HTTPURLResponse else { return nil }
        let idempotent = repeatable || ["GET", "HEAD", "PUT", "DELETE", "PATCH"].contains(method.uppercased())
        guard http.statusCode == 429 || ([500, 502, 503, 504].contains(http.statusCode) && idempotent) else { return nil }
        let announced = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "")
        return min(max(1, announced ?? pow(2, Double(attempt))), 30)
    }

    /// Sends a body to a content host with the same policy as `send`: a first 401 renews the token and repeats the
    /// block, a second means the account is gone. The block uploads of Dropbox and Box go straight to their own hosts
    /// and used to miss that, so a token that expired mid-upload failed the transfer with a bare "HTTP 401".
    func upload(_ request: inout URLRequest, from data: Data) async throws -> (Data, URLResponse) {
        let (body, response) = try await session.upload(for: request, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil else { return (body, response) }
        request.setValue(account.cloud.authorizationScheme + " " + (try await token(force: true)), forHTTPHeaderField: "Authorization")
        let (retriedBody, retriedResponse) = try await session.upload(for: request, from: data)
        if (retriedResponse as? HTTPURLResponse)?.statusCode == 401 { expireSession(); throw CloudError.sessionExpired(nil) }
        return (retriedBody, retriedResponse)
    }

    func json(_ url: URL, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try await request(url, method: method, body: body)
        for attempt in 0..<4 {
            try Task.checkCancellation()
            let (data, response) = try await send(&request)
            if attempt < 3, let delay = Self.retryDelay(response, method: method, attempt: attempt) {
                try await Task.sleep(for: .seconds(delay))
                continue
            }
            try HTTP.validate(response, data: data)
            return try HTTP.json(data)
        }
        throw CloudError.message(L("El servicio no responde."))
    }

    static func googleFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        let mime = value["mimeType"] as? String ?? "application/octet-stream"
        return CloudFile(id: id, name: name, mime: mime, size: (value["size"] as? String).flatMap(Int64.init), modified: date(value["modifiedTime"] as? String), webURL: (value["webViewLink"] as? String).flatMap(URL.init(string:)), isFolder: mime == "application/vnd.google-apps.folder")
    }
    static func microsoftFile(_ value: [String: Any]) -> CloudFile? {
        guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
        // Shared remote items need another drive identity; expose them as browser links in this MVP.
        let remote = value["remoteItem"] != nil
        return CloudFile(id: id, name: name, mime: remote ? "application/vnd.google-apps.shortcut" : ((value["file"] as? [String: Any])?["mimeType"] as? String ?? "application/octet-stream"), size: (value["size"] as? NSNumber)?.int64Value, modified: date(value["lastModifiedDateTime"] as? String), webURL: (value["webUrl"] as? String).flatMap(URL.init(string:)), isFolder: !remote && value["folder"] != nil)
    }
    /// Transfer addresses often come from a different fleet of servers than the API, and more than one provider
    /// hands them out over plain HTTP. macOS refuses to load those, and rightly so: even when the bytes are already
    /// encrypted, the address, the size and the timing would travel in the clear. Every provider here is reachable
    /// over TLS, so an address that arrives without it is upgraded rather than attempted as it came.
    nonisolated static func secureURL(_ address: String) -> URL? {
        guard var components = URLComponents(string: address), components.host?.isEmpty == false else { return nil }
        if components.scheme?.lowercased() == "http" { components.scheme = "https" }
        return components.url
    }
    nonisolated static func date(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
    /// Base of every Graph call: the signed-in user's own drive, or the document library this account is scoped to.
    var graphDrive: String {
        account.driveID.map { "https://graph.microsoft.com/v1.0/drives/" + Self.segment($0) } ?? "https://graph.microsoft.com/v1.0/me/drive"
    }
    /// Every Drive API call touching an item of a shared drive must opt in, or the server pretends it does not exist.
    var googleAllDrives: [URLQueryItem] {
        account.driveID == nil ? [] : [URLQueryItem(name: "supportsAllDrives", value: "true")]
    }
    /// Drive API calls of a shared-drive account must opt in explicitly, or the server pretends the items do not exist.
    func googleURL(_ string: String) -> URL {
        guard account.driveID != nil, var components = URLComponents(string: string) else { return URL(string: string)! }
        components.queryItems = (components.queryItems ?? []) + googleAllDrives
        return components.url ?? URL(string: string)!
    }
    /// Query items that restrict a listing or a search to the shared drive this account represents.
    var googleDriveScope: [URLQueryItem] {
        guard let drive = account.driveID else { return [] }
        return [URLQueryItem(name: "corpora", value: "drive"), URLQueryItem(name: "driveId", value: drive),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true"), URLQueryItem(name: "supportsAllDrives", value: "true")]
    }
    /// The identifier a shared drive uses for its own top level is the drive id itself.
    func googleParent(_ parent: String) -> String {
        parent == "root" ? (account.driveID ?? "root") : parent
    }

    func graphItem(_ id: String) -> String { id == "root" ? "root" : "items/" + Self.segment(id) }
    static func segment(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~")))! }

    /// Folders first, then by name. `onPage` receives the accumulated, sorted listing after each intermediate page so the
    /// explorer can show large folders progressively instead of waiting for the last page.
    /// `parent` is a folder id, "root", or one of `Collection.virtualRoots`, which map to provider-computed lists.
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        if let demo { return try demo.list(parent) }
        switch account.cloud {
        case .google: return try await googleList(parent: parent, onPage: onPage)
        case .microsoft: return try await graphList(parent: parent, onPage: onPage)
        case .dropbox: return try await dropboxList(parent: parent, onPage: onPage)
        case .ftp: return try await ftpList(parent: parent, onPage: onPage)
        case .volume: return try await volumeList(parent: parent)
        case .mega: return try await megaList(parent: parent)
        case .o2: return try await o2List(parent: parent)
        case .box: return try await boxList(parent: parent, onPage: onPage)
        case .webdav: return try await webdavList(parent: parent, onPage: onPage)
        }
    }
    private func googleList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        let fields = "nextPageToken,files(id,name,mimeType,size,modifiedTime,webViewLink)"

        var page: String?
        repeat {
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            switch parent {
            case Collection.recent.rootID:
                // One page of what the user opened last; folders are noise here.
                url.queryItems = [URLQueryItem(name: "q", value: "trashed = false and mimeType != 'application/vnd.google-apps.folder'"), URLQueryItem(name: "orderBy", value: "viewedByMeTime desc"), URLQueryItem(name: "pageSize", value: "100"), URLQueryItem(name: "fields", value: fields)]
            case Collection.shared.rootID:
                url.queryItems = [URLQueryItem(name: "q", value: "sharedWithMe = true and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "pageToken", value: page)]
            default:
                let escaped = googleParent(parent).replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
                url.queryItems = [URLQueryItem(name: "q", value: "'\(escaped)' in parents and trashed = false"), URLQueryItem(name: "pageSize", value: "1000"), URLQueryItem(name: "fields", value: fields), URLQueryItem(name: "pageToken", value: page)]
            }
            url.queryItems = (url.queryItems ?? []) + googleDriveScope
            let result = try await json(url.url!)
            files += (result["files"] as? [[String: Any]] ?? []).compactMap(Self.googleFile)
            page = parent == Collection.recent.rootID ? nil : result["nextPageToken"] as? String
            if page != nil { onPage?(Self.sorted(files)) }
        } while page != nil
        return Self.sorted(files)
    }
    private func graphList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        var files: [CloudFile] = []
        let select = "$select=id,name,size,folder,file,remoteItem,webUrl,lastModifiedDateTime"

        let route: String
        switch parent {
        case Collection.recent.rootID: route = "recent?\(select)"
        case Collection.shared.rootID: route = "sharedWithMe?\(select)"
        default: route = "\(graphItem(parent))/children?$top=200&\(select)"
        }
        var next: URL? = URL(string: "\(graphDrive)/\(route)")!
        while let url = next {
            guard url.scheme == "https", url.host == "graph.microsoft.com" else { throw CloudError.message(L("Paginación no válida.")) }
            let result = try await json(url)
            files += (result["value"] as? [[String: Any]] ?? []).compactMap(Self.microsoftFile)
            next = (result["@odata.nextLink"] as? String).flatMap(URL.init(string:))
            if next != nil { onPage?(Self.sorted(files)) }
        }
        return Self.sorted(files)
    }
    static func sorted(_ files: [CloudFile]) -> [CloudFile] {
        files.sorted { a, b in a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }

    func createFolder(name: String, parent: String) async throws -> String {
        if let demo { return try demo.add(name: name, parent: parent, folder: true) }
        let result: [String: Any]
        switch account.cloud {
        case .google:
            result = try await json(googleURL("https://www.googleapis.com/drive/v3/files"), method: "POST", body: ["name": name, "mimeType": "application/vnd.google-apps.folder", "parents": [googleParent(parent)]])
        case .microsoft:
            result = try await json(URL(string: "\(graphDrive)/\(graphItem(parent))/children")!, method: "POST", body: ["name": name, "folder": [:], "@microsoft.graph.conflictBehavior": "rename"])
        case .dropbox: return try await dropboxCreateFolder(name: name, parent: parent)
        case .box:
            result = try await json(URL(string: "https://api.box.com/2.0/folders")!, method: "POST", body: ["name": name, "parent": ["id": boxID(parent)]])
        case .webdav: return try await webdavCreateFolder(name: name, parent: parent)
        case .ftp: return try await ftpCreateFolder(name: name, parent: parent)
        case .volume: return try await volumeCreateFolder(name: name, parent: parent)
        case .mega: return try await megaCreateFolder(name: name, parent: parent)
        case .o2: return try await o2CreateFolder(name: name, parent: parent)
        }
        guard let id = result["id"] as? String else { throw CloudError.message(L("No se pudo crear la carpeta.")) }
        return id
    }

    // Uploads live in ResumableUpload.swift; the queue drives them with checkpoints. There is no second, simpler path.

    /// The authenticated request that yields a file's bytes. Each provider addresses content differently: a query
    /// parameter in Drive, a sub-path in Graph and Box, a JSON header in Dropbox and a plain URL in WebDAV.
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        switch account.cloud {
        case .google:
            var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))" + (exportMime == nil ? "" : "/export"))!
            parts.queryItems = [URLQueryItem(name: exportMime == nil ? "alt" : "mimeType", value: exportMime ?? "media")] + googleAllDrives
            return try await request(parts.url!)
        case .microsoft:
            return try await request(URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/content")!)
        case .box:
            return try await request(URL(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))/content")!)
        case .dropbox:
            var request = try await request(URL(string: "https://content.dropboxapi.com/2/files/download")!, method: "POST")
            request.setValue(Self.asciiJSON(["path": dropboxPath(file.id)]), forHTTPHeaderField: "Dropbox-API-Arg")
            return request
        case .webdav:
            return try await request(webdavURL(file.id))
        case .ftp, .volume, .mega, .o2:
            // None of them fetches with a plain request; `download` branches before reaching here.
            throw CloudError.message(L("Este proveedor no usa peticiones HTTP."))
        }
    }

    func download(file: CloudFile, to destination: URL, exportMime: String? = nil, maxBytes: Int64? = nil, progress: @escaping (Int64, Int64) -> Void = { _, _ in }) async throws {
        if let demo { try await demo.download(file, to: destination, maxBytes: maxBytes, progress: progress); return }
        if account.cloud == .o2 {
            try await o2Download(file: file, to: destination, progress: progress)
            return
        }
        if account.cloud == .mega {
            try await megaDownload(file: file, to: destination, progress: progress)
            return
        }
        if account.cloud == .volume {
            try await volumeDownload(file: file, to: destination, progress: progress)
            if let maxBytes, Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > maxBytes {
                try? FileManager.default.removeItem(at: destination)
                throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
            }
            return
        }
        if account.cloud == .ftp {
            try await ftpDownload(file: file, to: destination, progress: progress)
            if let maxBytes, Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > maxBytes {
                try? FileManager.default.removeItem(at: destination)
                throw CloudError.message(L("La vista previa supera el límite de descarga autorizado."))
            }
            return
        }
        let delegate = DownloadProgress(maxBytes: maxBytes) { bytes, total in Task { @MainActor in progress(bytes, total) } }
        var request = try await contentRequest(for: file, exportMime: exportMime)
        var temporary: URL, response: URLResponse
        do {
            (temporary, response) = try await session.download(for: request, delegate: delegate)
            if (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil {
                // Same policy as `send`: renew once, then treat a repeated 401 as a revoked session.
                try? FileManager.default.removeItem(at: temporary)
                request.setValue(account.cloud.authorizationScheme + " " + (try await token(force: true)), forHTTPHeaderField: "Authorization")
                (temporary, response) = try await session.download(for: request, delegate: delegate)
            }
        } catch {
            if delegate.exceededLimit { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        try Task.checkCancellation()
        if (response as? HTTPURLResponse)?.statusCode == 401, tokenProvider == nil { expireSession(); throw CloudError.sessionExpired(nil) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // The error body landed in the temporary file. Read a bounded prefix so the provider's message survives,
            // e.g. Google's explanation when an export exceeds its size limit.
            let body = (try? FileHandle(forReadingFrom: temporary))?.readData(ofLength: 64 * 1024) ?? Data()
            try HTTP.validate(response, data: body)
        }
        if let maxBytes {
            let actual = try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(actual) <= maxBytes else { throw CloudError.message(L("La vista previa supera el límite de descarga autorizado.")) }
        }
        // moveItem refuses to overwrite an existing destination.
        let downloaded = temporary
        try await blockingIO { try FileManager.default.moveItem(at: downloaded, to: destination) }
    }
}

final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: (Int64, Int64) -> Void
    let maxBytes: Int64?
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.withLock { exceeded } }
    init(maxBytes: Int64? = nil, report: @escaping (Int64, Int64) -> Void) { self.maxBytes = maxBytes; self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if let maxBytes, totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            lock.withLock { exceeded = true }; downloadTask.cancel(); return
        }
        report(totalBytesWritten, max(0, totalBytesExpectedToWrite))
    }
}
