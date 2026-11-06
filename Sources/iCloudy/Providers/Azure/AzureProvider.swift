import Foundation
import CryptoKit

/// How an Azure account signs its requests: with the storage account's key (Shared Key), or with a SAS token that
/// someone generated for it, which is appended to every request and signs nothing of its own.
enum AzureAuth: String { case sharedKey, sas }

/// Where an Azure account's requests go and how they are signed, read from the account. `serverURL` is the blob
/// endpoint (`https://cuenta.blob.core.windows.net`, or Azurite's `http://127.0.0.1:10000/devstoreaccount1`).
struct AzureLocation: Equatable {
    let accountName: String
    let endpoint: URLComponents
    /// The one container the account is restricted to, or nil to show every container the credential can list.
    let container: String?
    let auth: AzureAuth

    static let accountOption = "azureAccount", containerOption = "container", authOption = "azureAuth"

    init(accountName: String, endpoint: URLComponents, container: String?, auth: AzureAuth) {
        self.accountName = accountName; self.endpoint = endpoint
        self.container = container.flatMap { $0.isEmpty ? nil : $0 }; self.auth = auth
    }
    init(account: Account) throws {
        guard let server = account.serverURL, let components = URLComponents(string: server), components.host?.isEmpty == false,
              let name = account.options[Self.accountOption], !name.isEmpty else {
            throw CloudError.message(L("Esta cuenta de Azure no tiene una dirección válida. Vuelve a conectarla."))
        }
        self.init(accountName: name, endpoint: components, container: account.options[Self.containerOption],
                  auth: account.options[Self.authOption].flatMap(AzureAuth.init(rawValue:)) ?? .sharedKey)
    }

    /// The URL of `blob` in `container`, or of the service itself (List Containers). Blob names are encoded segment
    /// by segment, as they are signed.
    func url(container: String?, blob: String = "", query: [(String, String)] = [], sas: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = endpoint.scheme; components.host = endpoint.host; components.port = endpoint.port
        var path = endpoint.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        if let container {
            path += "/" + S3Signer.encode(container)
            if !blob.isEmpty { path += "/" + S3Signer.encode(blob, slash: true) }
        } else {
            path += "/"
        }
        components.percentEncodedPath = path
        var pairs = query.map { AzureSigner.encodeQuery($0.0) + "=" + AzureSigner.encodeQuery($0.1) }
        // A SAS token is pasted already encoded, as the portal gives it.
        if let sas, !sas.isEmpty { pairs.append(sas) }
        components.percentEncodedQuery = pairs.isEmpty ? nil : pairs.joined(separator: "&")
        guard let url = components.url else { throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor.")) }
        return url
    }
}

/// What a request needs before it is signed.
struct AzureCall {
    var method = "GET"
    var container: String?
    var blob = ""
    var query: [(String, String)] = []
    var headers: [String: String] = [:]
    var body: Data?
}

/// Azure Blob Storage. Containers are the roots, and folders are drawn from the common prefixes of a listing with
/// `/` as delimiter, as in S3; an item's id is `container/name`, a folder's ends in `/`. Every request is signed here
/// with Shared Key, or carries the account's SAS token. Uploads above 16 MiB go in blocks that resume; downloads go in
/// ranges and are checked against the blob's Content-MD5 when it has one.
@MainActor
final class AzureProvider: CloudSession, CloudProvider {
    /// Below this a file goes up in one Put Blob; above it, in blocks.
    var singleUploadLimit: Int64 = 16 * 1024 * 1024
    /// The block size, when a test wants it small.
    var blockOverride: Int64?
    /// Downloads above this go in ranged pieces, each repeated on its own if the connection drops.
    var downloadPiece: Int64 = 32 * 1024 * 1024
    /// How a refused request waits before it is repeated. Tests make it instant.
    var pause: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    private var cachedSecret: String?
    private var cachedLocation: AzureLocation?

    func location() throws -> AzureLocation {
        if let cachedLocation { return cachedLocation }
        let location = try AzureLocation(account: account)
        cachedLocation = location
        return location
    }
    /// The account key (Base64) or the SAS token, from the Keychain, read once per client.
    func secret() throws -> String {
        guard !invalidated else { throw CancellationError() }
        guard !sessionExpired else { throw CloudError.sessionExpired(nil) }
        if let cachedSecret { return cachedSecret }
        guard let credential = try credentials.read(account.credentialKey), !credential.secret.isEmpty else {
            expireSession(); throw CloudError.sessionExpired(nil)
        }
        cachedSecret = credential.secret
        return credential.secret
    }
}

extension AzureProvider {
    nonisolated static let folderMime = "application/vnd.google-apps.folder"
    nonisolated static let maximumBlocks: Int64 = 50_000
    nonisolated static let minimumBlock: Int64 = 8 * 1024 * 1024

    nonisolated static func blockSize(for total: Int64) -> Int64 {
        let mebibyte: Int64 = 1024 * 1024
        let needed = (total + maximumBlocks - 1) / maximumBlocks
        return max(minimumBlock, (needed + mebibyte - 1) / mebibyte * mebibyte)
    }
    /// Block ids are Base64 of strings of one length per blob; the session prefix keeps an abandoned attempt's
    /// uncommitted blocks out of a new one.
    nonisolated static func blockID(session: String, index: Int) -> String {
        Data("icloudy-\(session)-\(String(format: "%06d", index))".utf8).base64EncodedString()
    }

    func signedRequest(_ call: AzureCall) throws -> URLRequest {
        let location = try location()
        let secret = try secret()
        let url = try location.url(container: call.container, blob: call.blob, query: call.query, sas: location.auth == .sas ? secret : nil)
        var headers = call.headers
        headers["x-ms-date"] = AzureSigner.rfc1123.string(from: Date())
        headers["x-ms-version"] = AzureSigner.version
        if let body = call.body {
            headers["Content-Length"] = String(body.count)
            if headers["Content-Type"] == nil { headers["Content-Type"] = "application/octet-stream" }
        }
        var request = URLRequest(url: url)
        request.httpMethod = call.method
        request.timeoutInterval = call.body == nil ? 120 : 600
        Diagnostics.stamp(&request, account: account)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if location.auth == .sharedKey {
            guard let key = Data(base64Encoded: secret) else { expireSession(); throw CloudError.sessionExpired(nil) }
            request.setValue(AzureSigner.authorization(method: call.method, url: url, headers: headers, account: location.accountName, key: key),
                             forHTTPHeaderField: "Authorization")
        }
        return request
    }

    /// The error a refusal stands for: an expired session for a key or token Azure no longer accepts, otherwise a
    /// `ServiceError` with Azure's own code and message, which `CloudError.kind` classifies.
    func failure(_ http: HTTPURLResponse, data: Data) -> Error {
        let body = AzureXML.error(data)
        let code = body?.code ?? http.value(forHTTPHeaderField: "x-ms-error-code")
        if http.statusCode == 403, ["AuthenticationFailed", "AuthorizationFailure", "InvalidAuthenticationInfo"].contains(code ?? "") {
            let reason = L("Azure no acepta la clave o el token SAS de esta cuenta. Vuelve a conectarla con unos válidos.")
            expireSession(reason)
            return CloudError.sessionExpired(reason)
        }
        let detail: String
        switch code {
        case "ContainerNotFound": detail = L("Ese contenedor no existe en la cuenta de almacenamiento.")
        case "BlobNotFound": detail = L("Ese archivo ya no está en Azure.")
        case "BlobAlreadyExists", "ConditionNotMet": detail = L("Ya existe un elemento con ese nombre en el destino.")
        case "Md5Mismatch", "InvalidMd5": detail = L("Azure rechazó un bloque porque su suma MD5 no coincidía: los datos se dañaron por el camino.")
        default: detail = body?.message.map { L("Azure respondió: \($0)") } ?? L("El servicio devolvió HTTP \(http.statusCode).")
        }
        return ServiceError(status: http.statusCode, detail: detail, code: code, retryAfter: RetryAfter.seconds(http))
    }

    /// Signs and sends `call`, repeating it after a pause for the refusals Azure asks to repeat (500, 503
    /// `ServerBusy`) when the method may be repeated.
    func azure(_ call: AzureCall) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            let request = try signedRequest(call)
            let (data, response): (Data, URLResponse)
            if let body = call.body { (data, response) = try await session.upload(for: request, from: body, delegate: RedirectGuard.shared) }
            else { (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared) }
            guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
            if (200..<300).contains(http.statusCode) { return (data, http) }
            if attempt < 3, let delay = Self.retryDelay(http, method: call.method, attempt: attempt) {
                attempt += 1
                Diagnostics.retrying(account, method: call.method, url: request.url, status: http.statusCode, attempt: attempt, delay: delay)
                try await pause(delay)
                continue
            }
            throw failure(http, data: data)
        }
    }

    func path(_ id: String) throws -> S3Path? { S3Path(id: id, bucket: try location().container) }
    func object(_ id: String) throws -> S3Path {
        guard let path = try path(id) else { throw CloudError.message(L("Elige un contenedor: la lista de contenedores no es una carpeta.")) }
        return path
    }

    nonisolated static func folder(_ path: S3Path) -> CloudFile {
        CloudFile(id: path.id, name: path.name, mime: folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    nonisolated static func file(_ blob: AzureBlob, container: String) -> CloudFile {
        let path = S3Path(bucket: container, key: blob.name)
        if path.isFolder { return folder(path) }
        return CloudFile(id: path.id, name: path.name, mime: mime(forName: path.name), size: blob.size, modified: blob.modified,
                         webURL: nil, isFolder: false, checksum: AzureXML.hexMD5(blob.md5).map { ContentHash(algorithm: .md5, value: $0) })
    }

    /// Every page of a listing, following `NextMarker`. With `delimiter` it is one folder; without, the whole prefix.
    func listPages(container: String?, prefix: String = "", delimiter: Bool, onPage: ((AzureListing) -> Void)? = nil) async throws -> AzureListing {
        var all = AzureListing()
        var marker: String?
        var seen: Set<String> = []
        repeat {
            var query: [(String, String)] = container == nil ? [("comp", "list")] : [("restype", "container"), ("comp", "list")]
            if container != nil, !prefix.isEmpty { query.append(("prefix", prefix)) }
            if delimiter, container != nil { query.append(("delimiter", "/")) }
            if let marker { query.append(("marker", marker)) }
            let page = try AzureXML.listing(try await azure(AzureCall(container: container, query: query)).0)
            onPage?(page)
            all.prefixes += page.prefixes; all.blobs += page.blobs; all.containers += page.containers
            marker = page.next
            // A server that hands back the same marker would keep this loop going for ever.
            if let marker, !seen.insert(marker).inserted {
                throw CloudError.message(L("El servicio devolvió la misma página una y otra vez, así que se ha dejado de pedir más."))
            }
        } while marker != nil
        return all
    }

    func azureList(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        guard let folder = try path(parent) else {
            let containers = try await listPages(container: nil, delimiter: false).containers.map { Self.folder(S3Path(bucket: $0, key: "")) }
            onPage?(containers)
            return Self.sorted(containers)
        }
        guard folder.isFolder else { throw CloudError.message(L("Esto es un archivo, no una carpeta.")) }
        func items(_ page: AzureListing) -> [CloudFile] {
            // The folder's own marker is listed among its contents; it is the folder, not a child of it.
            page.prefixes.filter { $0 != folder.key }.map { Self.folder(S3Path(bucket: folder.bucket, key: $0)) }
                + page.blobs.filter { $0.name != folder.key }.map { Self.file($0, container: folder.bucket) }
        }
        let listing = try await listPages(container: folder.bucket, prefix: folder.key, delimiter: true) { page in
            let batch = items(page)
            if !batch.isEmpty { onPage?(batch) }
        }
        var ids: Set<String> = []
        return Self.sorted(items(listing).filter { ids.insert($0.id).inserted })
    }

    /// Blob storage has no folders; a zero-byte blob named `nombre/`, marked the way Azure's own tools mark one,
    /// stands for an empty one.
    func azureCreateFolder(name: String, parent: String) async throws -> String {
        guard let folder = try path(parent) else {
            throw CloudError.message(L("iCloudy no crea contenedores. Créalo en el portal de Azure y aparecerá aquí."))
        }
        let marker = S3Path(bucket: folder.bucket, key: folder.key + name + "/")
        var call = AzureCall(method: "PUT", container: marker.bucket, blob: marker.key)
        call.body = Data()
        call.headers = ["x-ms-blob-type": "BlockBlob", "x-ms-meta-hdi_isfolder": "true", "If-None-Match": "*"]
        _ = try await azure(call)
        return marker.id
    }

    /// Get Blob Properties, as a listed item.
    func head(_ path: S3Path) async throws -> (file: CloudFile, response: HTTPURLResponse) {
        let (_, response) = try await azure(AzureCall(method: "HEAD", container: path.bucket, blob: path.key))
        let blob = AzureBlob(name: path.key, size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
                             modified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(AzureSigner.rfc1123.date(from:)),
                             md5: response.value(forHTTPHeaderField: "Content-MD5"))
        return (Self.file(blob, container: path.bucket), response)
    }

    /// Azure overwrites a blob without a word; renaming onto an existing name would lose whatever had it.
    func ensureFree(_ target: S3Path) async throws {
        let taken: Bool
        if target.isFolder {
            let query: [(String, String)] = [("restype", "container"), ("comp", "list"), ("prefix", target.key), ("maxresults", "1")]
            taken = !(try AzureXML.listing(try await azure(AzureCall(container: target.bucket, query: query)).0)).blobs.isEmpty
        } else {
            do { _ = try await head(target); taken = true }
            catch let error as ServiceError where error.status == 404 { taken = false }
        }
        if taken { throw CloudError.message(L("Ya existe un elemento con ese nombre en el destino.")) }
    }

    func azureTrail(id: String) throws -> [CloudFile] {
        guard let path = try path(id) else { return [] }
        var trail: [CloudFile] = []
        if try location().container == nil { trail.append(Self.folder(S3Path(bucket: path.bucket, key: ""))) }
        var segments = path.key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if !segments.isEmpty { segments.removeLast() }
        var prefix = ""
        for segment in segments {
            prefix += segment + "/"
            trail.append(Self.folder(S3Path(bucket: path.bucket, key: prefix)))
        }
        return trail
    }

    /// Prefix search, the only kind Blob Storage lists: from the top of each container, one container after the other.
    func azureSearch(term: String, cursor: String?) async throws -> SearchPage {
        let prefix = term.hasPrefix("/") ? String(term.dropFirst()) : term
        let fixed = try location().container
        let containers: [String]
        if let fixed { containers = [fixed] } else { containers = try await listPages(container: nil, delimiter: false).containers }
        var index = 0
        var marker: String?
        if let cursor {
            let parts = cursor.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            index = Int(parts[0]) ?? 0
            marker = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        }
        guard containers.indices.contains(index) else { return SearchPage(hits: [], next: nil, incomplete: true) }
        let container = containers[index]
        var query: [(String, String)] = [("restype", "container"), ("comp", "list"), ("prefix", prefix), ("maxresults", "200")]
        if let marker { query.append(("marker", marker)) }
        let page: AzureListing
        do { page = try AzureXML.listing(try await azure(AzureCall(container: container, query: query)).0) }
        catch let error as ServiceError where fixed == nil && [403, 404].contains(error.status) { page = AzureListing() }
        let hits = page.blobs.filter { !$0.name.hasSuffix("/") }.map { blob -> SearchHit in
            let path = S3Path(bucket: container, key: blob.name)
            let parent = fixed != nil && path.parentKey.isEmpty ? "root" : S3Path(bucket: container, key: path.parentKey).id
            return SearchHit(accountID: account.id, file: Self.file(blob, container: container), parentID: parent)
        }
        let next = page.next.map { "\(index)\n\($0)" } ?? (index + 1 < containers.count ? "\(index + 1)\n" : nil)
        return SearchPage(hits: hits, next: next, incomplete: true)
    }

    /// A read-only SAS link to one blob. Only an account connected with its key can sign one: a SAS token cannot sign
    /// another, and handing out the account's own token would give away everything it allows.
    func temporaryLink(for file: CloudFile, lifetime: Int) throws -> URL {
        guard !file.isFolder else { throw CloudError.message(L("Azure solo crea enlaces temporales de archivos, no de carpetas.")) }
        let location = try location()
        guard location.auth == .sharedKey, let key = Data(base64Encoded: try secret()) else {
            throw CloudError.message(L("Esta cuenta de Azure está conectada con un token SAS, que no puede firmar enlaces nuevos. Conéctala con la clave de la cuenta para crearlos."))
        }
        let path = try object(file.id)
        let now = Date()
        let query = AzureSigner.blobSAS(account: location.accountName, container: path.bucket, blob: path.key, key: key,
                                        start: now.addingTimeInterval(-300), expiry: now.addingTimeInterval(TimeInterval(lifetime)))
        var components = URLComponents(url: try location.url(container: path.bucket, blob: path.key), resolvingAgainstBaseURL: false)
        components?.percentEncodedQuery = query.map { $0.name + "=" + AzureSigner.encodeQuery($0.value ?? "") }.joined(separator: "&")
        guard let link = components?.url else { throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor.")) }
        return link
    }
}

extension AzureProvider: TemporaryLinkProvider {}

extension AzureProvider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] { try await azureList(parent: parent, onPage: onPage) }
    func createFolder(name: String, parent: String) async throws -> String { try await azureCreateFolder(name: name, parent: parent) }
    /// A signed GET, for the callers that read the bytes themselves.
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        let path = try object(file.id)
        return try signedRequest(AzureCall(container: path.bucket, blob: path.key))
    }
    func rename(file: CloudFile, name: String) async throws {
        let source = try object(file.id)
        guard !source.key.isEmpty else { throw CloudError.message(L("iCloudy no renombra contenedores.")) }
        try await azureRelocate(file, from: source, to: S3Path(bucket: source.bucket, key: source.parentKey + name + (source.isFolder ? "/" : "")), keepSource: false)
    }
    func move(file: CloudFile, to destination: String) async throws {
        let source = try object(file.id)
        guard !source.key.isEmpty else { throw CloudError.message(L("iCloudy no mueve contenedores.")) }
        let folder = try object(destination)
        try await azureRelocate(file, from: source, to: S3Path(bucket: folder.bucket, key: folder.key + source.name + (source.isFolder ? "/" : "")), keepSource: false)
    }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        let source = try object(file.id)
        guard !source.key.isEmpty else { throw CloudError.message(L("iCloudy no copia contenedores enteros. Copia las carpetas que contiene.")) }
        let folder = try object(destination)
        try await azureRelocate(file, from: source, to: S3Path(bucket: folder.bucket, key: folder.key + source.name + (source.isFolder ? "/" : "")), keepSource: true)
    }
    /// Blob Storage has a soft delete only when the account switches it on, and iCloudy cannot list it: this deletes
    /// for good, and the confirmation says so.
    func trash(file: CloudFile) async throws { try await azureDelete(try object(file.id)) }
    func publicLink(for file: CloudFile) async throws -> URL { try temporaryLink(for: file, lifetime: 24 * 3600) }
    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        try await azureSearch(term: term, cursor: cursor)
    }
    func folderTrail(id: String) async throws -> [CloudFile] { try azureTrail(id: id) }
    func storageQuota() async throws -> StorageQuota {
        throw CloudError.message(L("Azure no informa del espacio disponible: una cuenta de almacenamiento no tiene un límite que consultar, se paga por lo que se guarda."))
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try await azureUpload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await azureDownload(file: file, to: destination, maxBytes: maxBytes, progress: progress)
    }
    func currentMetadata(of file: CloudFile) async throws -> CloudFile? {
        let path = try object(file.id)
        guard !path.isFolder else { return nil }
        return try await head(path).file
    }
    /// Uncommitted blocks are dropped by Azure after a week; nothing can delete them sooner without committing them.
    func abandonUploadSessions(urls: [URL], sessionIDs: [String]) async {}
    func identityChange(file: CloudFile, name: String, destination: String?) throws -> RemoteIdentityChange {
        let source = try object(file.id)
        let suffix = source.isFolder ? "/" : ""
        let target: S3Path
        if let destination {
            let folder = try object(destination)
            target = S3Path(bucket: folder.bucket, key: folder.key + source.name + suffix)
        } else {
            target = S3Path(bucket: source.bucket, key: source.parentKey + name + suffix)
        }
        return RemoteIdentityChange(oldID: file.id, newID: target.id, name: name, descendants: file.isFolder)
    }
}
