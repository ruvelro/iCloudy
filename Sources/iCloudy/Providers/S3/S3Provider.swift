import Foundation
import CryptoKit

/// Amazon S3 and the services that copy its API: Backblaze B2, Wasabi, Cloudflare R2, MinIO, Scaleway, Spaces…
///
/// S3 has no folders, only keys with slashes in them, so iCloudy draws folders from the common prefixes of a listing
/// and from the empty `name/` objects that the consoles create. An item's id is `bucket/key`, a folder's ends with
/// `/`, and a bucket on its own is `bucket/`. "root" is the account's bucket when it was connected to one, and the
/// list of buckets otherwise. Every request is signed here with SigV4; the secret key never leaves the Mac.
@MainActor
final class S3Provider: CloudSession, CloudProvider {
    /// Where each bucket lives, learnt from listings and from the redirects of AWS. A bucket of another region only
    /// answers at that region's host, and the account was connected to one region.
    var bucketRegions: [String: String] = [:]
    /// Objects whose last download said they are encrypted with KMS or with a customer key. Their ETag is not the
    /// MD5 of the content, so it cannot be checked as one.
    var opaqueChecksums: Set<String> = []
    /// Difference between the server's clock and this Mac's, learnt from a `RequestTimeTooSkewed`.
    var clockOffset: TimeInterval = 0
    /// Reports how many of a folder's objects have been copied, while a folder is renamed, moved or copied.
    var relocationProgress: ((Int, Int) -> Void)?
    /// Downloads above this go in ranged pieces, each repeated on its own if the connection drops.
    var downloadPiece: Int64 = 64 * 1024 * 1024
    /// How a refused request waits before it is repeated. Tests replace it so that retries do not take seconds.
    var pause: (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    private var cachedKeys: S3Keys?
    private var cachedLocation: S3Location?
}

/// A place in an S3 account: the bucket, and the key inside it. An empty key is the bucket itself.
struct S3Path: Equatable {
    let bucket: String
    let key: String
    var isFolder: Bool { key.isEmpty || key.hasSuffix("/") }
    var id: String { bucket + "/" + key }
    /// The last segment, without the slash a folder ends with. The bucket's own name for the bucket.
    var name: String {
        guard !key.isEmpty else { return bucket }
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        return trimmed.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
    }
    /// The key of the folder that holds this item, `""` at the top of the bucket.
    var parentKey: String {
        let trimmed = key.hasSuffix("/") ? String(key.dropLast()) : key
        guard let slash = trimmed.lastIndex(of: "/") else { return "" }
        return String(trimmed[...slash])
    }
    /// `root` is the account's bucket when it has one, and nothing otherwise: the list of buckets is not a place.
    init?(id: String, bucket fixed: String?) {
        if id == "root" {
            guard let fixed else { return nil }
            self.init(bucket: fixed, key: "")
            return
        }
        guard let slash = id.firstIndex(of: "/") else {
            guard !id.isEmpty else { return nil }
            self.init(bucket: id, key: "")
            return
        }
        self.init(bucket: String(id[..<slash]), key: String(id[id.index(after: slash)...]))
    }
    init(bucket: String, key: String) { self.bucket = bucket; self.key = key }
}

/// What a request needs before it is signed.
struct S3Call {
    var method = "GET"
    var bucket: String?
    var key = ""
    var query: [(String, String?)] = []
    var headers: [String: String] = [:]
    var body: Data?
    /// The hash declared for the body. nil means the real SHA-256 of `body`, or of nothing.
    var payloadHash: String?
    /// A POST that does the same thing twice as once, and may therefore be repeated after a 5xx.
    var repeatable = false
    /// CompleteMultipartUpload and the copies can fail after answering 200: the `<Error>` is in the body.
    var errorsInBody = false
}

extension S3Provider {
    /// Where the account's requests go, read once from the account.
    func location() throws -> S3Location {
        if let cachedLocation { return cachedLocation }
        let location = try S3Location(account: account)
        cachedLocation = location
        return location
    }
    /// The location to address `bucket` at, which on AWS depends on the bucket's own region.
    func location(for bucket: String?) throws -> S3Location {
        let base = try location()
        guard let bucket, let region = bucketRegions[bucket], region != base.region else { return base }
        return base.moved(to: region)
    }

    /// The access key and its secret, from the Keychain, read once per client.
    func keys() throws -> S3Keys {
        guard !invalidated else { throw CancellationError() }
        guard !sessionExpired else { throw CloudError.sessionExpired(nil) }
        if let cachedKeys { return cachedKeys }
        guard let credential = try credentials.read(account.credentialKey), !credential.accessToken.isEmpty, !credential.secret.isEmpty else {
            expireSession()
            throw CloudError.sessionExpired(nil)
        }
        let keys = S3Keys(accessKey: credential.accessToken, secretKey: credential.secret)
        cachedKeys = keys
        return keys
    }

    func path(_ id: String) throws -> S3Path? { S3Path(id: id, bucket: try location().bucket) }

    /// The object or folder behind `file`, refusing the list of buckets, which is not an item.
    func object(_ id: String) throws -> S3Path {
        guard let path = try path(id) else { throw CloudError.message(L("Elige un bucket: la lista de buckets no es una carpeta.")) }
        return path
    }

    // MARK: - Transport

    func signedRequest(_ call: S3Call) throws -> URLRequest {
        let keys = try keys()
        let location = try location(for: call.bucket)
        let url = try location.url(bucket: call.bucket, key: call.key, query: call.query)
        let date = Date().addingTimeInterval(clockOffset)
        let payload = call.payloadHash ?? (call.body.map(S3Signer.sha256Hex) ?? S3Signer.emptyPayloadHash)
        var headers = call.headers
        headers["x-amz-date"] = S3Signer.timestamp(date)
        headers["x-amz-content-sha256"] = payload
        var request = URLRequest(url: url)
        request.httpMethod = call.method
        request.timeoutInterval = call.body == nil ? 120 : 600
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(S3Signer.authorization(method: call.method, url: url, headers: headers, payloadHash: payload,
                                                keys: keys, region: location.region, date: date),
                         forHTTPHeaderField: "Authorization")
        return request
    }

    /// What to do with a refusal: try again (after a pause, or straight away when the request itself was wrong in a
    /// way this client can fix) or give up with an error a person can read.
    enum Verdict { case again(Double), fail(Error) }
    struct RetryState { var attempt = 0; var movedRegion = false; var fixedClock = false }

    func judge(_ response: HTTPURLResponse, data: Data, call: S3Call, state: inout RetryState) -> Verdict {
        let body = S3XML.error(data)
        let status = response.statusCode
        // AWS answers a bucket of another region with a redirect it does not follow itself, naming the region.
        if !state.movedRegion, (try? location().service) == .aws, let bucket = call.bucket,
           let region = response.value(forHTTPHeaderField: "x-amz-bucket-region") ?? body?.region,
           region != (try? location(for: bucket).region),
           body.map({ S3Failure.wrongRegion.contains($0.code) }) ?? [301, 307, 400].contains(status) {
            bucketRegions[bucket] = region
            state.movedRegion = true
            return .again(0)
        }
        // A Mac whose clock drifted signs requests from the past. The server says what time it is; adopting its
        // clock for this account saves a refusal that would otherwise repeat on every request.
        if !state.fixedClock, body?.code == "RequestTimeTooSkewed",
           let server = body?.serverTime ?? response.value(forHTTPHeaderField: "Date").flatMap(Self.httpDate) {
            clockOffset = server.timeIntervalSinceNow
            state.fixedClock = true
            return .again(0)
        }
        if state.attempt < 3 {
            var delay = Self.retryDelay(response, method: call.method, attempt: state.attempt, repeatable: call.repeatable)
            // The same transient failure, reported inside a 200 by CompleteMultipartUpload or a copy.
            if delay == nil, status == 200, let code = body?.code, S3Failure.transient.contains(code),
               call.repeatable || ["GET", "HEAD", "PUT", "DELETE"].contains(call.method) {
                delay = min(pow(2, Double(state.attempt)), 30)
            }
            if let delay { state.attempt += 1; return .again(delay) }
        }
        if body?.code == "InvalidAccessKeyId" {
            let message = S3Failure.message(status: status, body: body, bucket: call.bucket)
            expireSession(message)
            return .fail(CloudError.sessionExpired(message))
        }
        let error = S3Failure.error(response, data: data, bucket: call.bucket)
        // An error inside a 200 is still an error, and a server-side one: keep it retryable for the queue.
        return .fail(status == 200 ? ServiceError(status: 500, detail: error.detail, code: error.code) : error)
    }

    /// Signs and sends `call`, repeating it as S3 asks: after a pause for 5xx and SlowDown, at once at the right
    /// region or with the server's clock. `sent` reports the bytes of the body as they leave.
    func s3(_ call: S3Call, sent: ((Int64) -> Void)? = nil) async throws -> (Data, HTTPURLResponse) {
        var state = RetryState()
        while true {
            try Task.checkCancellation()
            let request = try signedRequest(call)
            let (data, response): (Data, URLResponse)
            if let body = call.body {
                let delegate: RedirectGuard = sent.map { report in UploadProgress { bytes in Task { @MainActor in report(bytes) } } } ?? RedirectGuard.shared
                (data, response) = try await session.upload(for: request, from: body, delegate: delegate)
            } else {
                (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
            }
            guard let http = response as? HTTPURLResponse else { throw CloudError.message(L("Respuesta HTTP no válida.")) }
            let failed = !(200..<300).contains(http.statusCode) || (call.errorsInBody && S3XML.error(data) != nil)
            guard failed else { return (data, http) }
            switch judge(http, data: data, call: call, state: &state) {
            case .again(let delay): if delay > 0 { try await pause(delay) }
            case .fail(let error): throw error
            }
        }
    }

    private nonisolated static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
    nonisolated static func httpDate(_ text: String) -> Date? { rfc1123.date(from: text) }

    /// S3 lists an MD5 as the ETag only for objects uploaded in one piece and not encrypted with KMS. A multipart
    /// ETag carries `-N`; anything else that is not 32 hexadecimal digits is not a digest either.
    nonisolated static func isPlainMD5(_ etag: String) -> Bool {
        etag.count == 32 && etag.allSatisfy(\.isHexDigit)
    }
    /// True when the response says the object is encrypted in a way that makes its ETag something other than an MD5.
    nonisolated static func encrypted(_ response: HTTPURLResponse) -> Bool {
        let kind = response.value(forHTTPHeaderField: "x-amz-server-side-encryption")?.lowercased() ?? ""
        return kind.hasPrefix("aws:kms") || response.value(forHTTPHeaderField: "x-amz-server-side-encryption-customer-algorithm") != nil
    }

    // MARK: - Items

    nonisolated static let folderMime = "application/vnd.google-apps.folder"

    nonisolated static func folder(_ path: S3Path) -> CloudFile {
        CloudFile(id: path.id, name: path.name, mime: folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
    }
    nonisolated static func file(_ object: S3Object, bucket: String) -> CloudFile {
        let path = S3Path(bucket: bucket, key: object.key)
        if path.isFolder { return folder(path) }
        return CloudFile(id: path.id, name: path.name, mime: mime(forName: path.name), size: object.size, modified: object.modified,
                         webURL: nil, isFolder: false,
                         checksum: object.etag.flatMap { isPlainMD5($0) ? ContentHash(algorithm: .md5, value: $0.lowercased()) : nil })
    }

    /// Every page of a prefix. With `delimiter` it is one folder; without, everything under the prefix at any depth.
    func listPages(bucket: String, prefix: String, delimiter: Bool, onPage: ((S3Listing) -> Void)? = nil) async throws -> S3Listing {
        var all = S3Listing()
        var token: String?
        var seen: Set<String> = []
        repeat {
            var query: [(String, String?)] = [("list-type", "2"), ("prefix", prefix)]
            if delimiter { query.append(("delimiter", "/")) }
            if let token { query.append(("continuation-token", token)) }
            let (data, _) = try await s3(S3Call(bucket: bucket, query: query))
            let page = try S3XML.listing(data)
            onPage?(page)
            all.prefixes += page.prefixes; all.objects += page.objects
            token = page.next
            // A server that hands back the same token would keep this loop going for ever.
            if let token, !seen.insert(token).inserted {
                throw CloudError.message(L("El proveedor repitió una página. Se conservan los resultados recibidos; vuelve a buscar para actualizar."))
            }
        } while token != nil
        return all
    }

    func s3Buckets() async throws -> [S3Bucket] {
        var buckets: [S3Bucket] = []
        var token: String?
        repeat {
            let (data, _) = try await s3(S3Call(bucket: nil, query: token.map { [("continuation-token", $0)] } ?? []))
            let page = try S3XML.buckets(data)
            buckets += page.buckets
            token = page.next
        } while token != nil && buckets.count < 100_000
        if try location().service == .aws {
            for bucket in buckets { if let region = bucket.region { bucketRegions[bucket.name] = region } }
        }
        return buckets
    }

    func s3List(parent: String, onPage: (([CloudFile]) -> Void)?) async throws -> [CloudFile] {
        guard let folder = try path(parent) else {
            let files = try await s3Buckets().map { Self.folder(S3Path(bucket: $0.name, key: "")) }
            onPage?(files)
            return Self.sorted(files)
        }
        guard folder.isFolder else { throw CloudError.message(L("Esto es un archivo, no una carpeta.")) }
        var seen: Set<String> = []
        let listing = try await listPages(bucket: folder.bucket, prefix: folder.key, delimiter: true) { page in
            // The folder's own marker is listed among its contents; it is the folder, not a child of it.
            let prefixes = page.prefixes.filter { $0 != folder.key }.map { Self.folder(S3Path(bucket: folder.bucket, key: $0)) }
            let objects = page.objects.filter { $0.key != folder.key }.map { Self.file($0, bucket: folder.bucket) }
            let batch = (prefixes + objects).filter { seen.insert($0.id).inserted }
            if !batch.isEmpty { onPage?(batch) }
        }
        var files: [CloudFile] = []
        var ids: Set<String> = []
        for item in listing.prefixes.filter({ $0 != folder.key }).map({ Self.folder(S3Path(bucket: folder.bucket, key: $0)) })
            + listing.objects.filter({ $0.key != folder.key }).map({ Self.file($0, bucket: folder.bucket) }) where ids.insert(item.id).inserted {
            files.append(item)
        }
        return Self.sorted(files)
    }

    func s3CreateFolder(name: String, parent: String) async throws -> String {
        guard let folder = try path(parent) else {
            throw CloudError.message(L("iCloudy no crea buckets. Créalo en la consola de tu proveedor y aparecerá aquí."))
        }
        let marker = S3Path(bucket: folder.bucket, key: folder.key + name + "/")
        var call = S3Call(method: "PUT", bucket: marker.bucket, key: marker.key)
        call.body = Data()
        call.headers["Content-Type"] = "application/x-directory"
        _ = try await s3(call)
        return marker.id
    }

    /// HEAD of one object, as a listed item. A missing object is a 404 `ServiceError`.
    func head(_ path: S3Path) async throws -> (file: CloudFile, etag: String?, encrypted: Bool) {
        let (_, response) = try await s3(S3Call(method: "HEAD", bucket: path.bucket, key: path.key))
        let etag = S3XML.etag(response.value(forHTTPHeaderField: "ETag"))
        let object = S3Object(key: path.key, size: Int64(response.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0,
                              modified: response.value(forHTTPHeaderField: "Last-Modified").flatMap(Self.httpDate), etag: etag)
        return (Self.file(object, bucket: path.bucket), etag, Self.encrypted(response))
    }

    /// Refuses to overwrite: S3 replaces an object without a word, which turns a rename onto an existing name into
    /// the loss of whatever had that name.
    func ensureFree(_ target: S3Path) async throws {
        let taken: Bool
        if target.isFolder {
            let (data, _) = try await s3(S3Call(bucket: target.bucket, query: [("list-type", "2"), ("prefix", target.key), ("max-keys", "1")]))
            taken = !(try S3XML.listing(data)).objects.isEmpty
        } else {
            do { _ = try await head(target); taken = true }
            catch let error as ServiceError where error.status == 404 { taken = false }
        }
        if taken { throw CloudError.message(L("Ya existe un elemento con ese nombre en el destino.")) }
    }

    /// Breadcrumbs come from the key itself; the bucket is one more crumb unless the account is tied to it.
    func s3Trail(id: String) throws -> [CloudFile] {
        guard let path = try path(id) else { return [] }
        var trail: [CloudFile] = []
        if try location().bucket == nil { trail.append(Self.folder(S3Path(bucket: path.bucket, key: ""))) }
        var segments = path.key.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if path.isFolder, !segments.isEmpty { segments.removeLast() }   // what follows the closing slash
        else if !segments.isEmpty { segments.removeLast() }             // a file is not a crumb of its own trail
        var prefix = ""
        for segment in segments {
            prefix += segment + "/"
            trail.append(Self.folder(S3Path(bucket: path.bucket, key: prefix)))
        }
        return trail
    }

    /// Prefix search, the only kind S3 has: the term is the start of a key, from the top of the bucket. With no
    /// bucket of its own, the account searches its buckets one after the other. Always flagged as incomplete,
    /// because a name in the middle of a path is not found this way.
    func s3Search(term: String, cursor: String?) async throws -> SearchPage {
        let prefix = term.hasPrefix("/") ? String(term.dropFirst()) : term
        let fixed = try location().bucket
        let buckets: [String]
        if let fixed { buckets = [fixed] } else { buckets = try await s3Buckets().map(\.name) }
        var index = 0
        var token: String?
        if let cursor {
            let parts = cursor.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            index = Int(parts[0]) ?? 0
            token = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        }
        guard buckets.indices.contains(index) else { return SearchPage(hits: [], next: nil, incomplete: true) }
        let bucket = buckets[index]
        var query: [(String, String?)] = [("list-type", "2"), ("prefix", prefix), ("max-keys", "200")]
        if let token { query.append(("continuation-token", token)) }
        let listing: S3Listing
        do { listing = try S3XML.listing(try await s3(S3Call(bucket: bucket, query: query)).0) }
        catch let error as ServiceError where fixed == nil && [403, 404].contains(error.status) {
            // A key may list every bucket and still be barred from some; that is no reason to stop at it.
            listing = S3Listing()
        }
        let hits = listing.objects.map { object -> SearchHit in
            let path = S3Path(bucket: bucket, key: object.key)
            let parent = fixed != nil && path.parentKey.isEmpty ? "root" : S3Path(bucket: bucket, key: path.parentKey).id
            return SearchHit(accountID: account.id, file: Self.file(object, bucket: bucket), parentID: parent)
        }
        let next = listing.next.map { "\(index)\n\($0)" } ?? (index + 1 < buckets.count ? "\(index + 1)\n" : nil)
        return SearchPage(hits: hits, next: next, incomplete: true)
    }

    /// A link that works for anyone until it expires, and cannot be revoked before that without retiring the key.
    func temporaryLink(for file: CloudFile, lifetime: Int) throws -> URL {
        guard !file.isFolder else { throw CloudError.message(L("S3 solo crea enlaces temporales de archivos, no de carpetas.")) }
        let path = try object(file.id)
        let location = try location(for: path.bucket)
        let url = try location.url(bucket: path.bucket, key: path.key)
        guard let link = S3Signer.presign(url: url, keys: try keys(), region: location.region,
                                          date: Date().addingTimeInterval(clockOffset), expires: lifetime) else {
            throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor."))
        }
        return link
    }
}

extension S3Provider {
    func list(parent: String, onPage: (([CloudFile]) -> Void)? = nil) async throws -> [CloudFile] {
        try await s3List(parent: parent, onPage: onPage)
    }
    func createFolder(name: String, parent: String) async throws -> String {
        try await s3CreateFolder(name: name, parent: parent)
    }
    /// A presigned GET, good for an hour, so that whoever reads it needs no signing of their own.
    func contentRequest(for file: CloudFile, exportMime: String?) async throws -> URLRequest {
        URLRequest(url: try temporaryLink(for: file, lifetime: 3600))
    }
    func rename(file: CloudFile, name: String) async throws {
        let source = try object(file.id)
        guard !source.key.isEmpty else { throw CloudError.message(L("iCloudy no renombra buckets.")) }
        let target = S3Path(bucket: source.bucket, key: source.parentKey + name + (source.isFolder ? "/" : ""))
        try await s3Relocate(file, from: source, to: target, keepSource: false)
    }
    func move(file: CloudFile, to destination: String) async throws {
        let source = try object(file.id)
        guard !source.key.isEmpty else { throw CloudError.message(L("iCloudy no mueve buckets.")) }
        let folder = try object(destination)
        try await s3Relocate(file, from: source, to: S3Path(bucket: folder.bucket, key: folder.key + source.name + (source.isFolder ? "/" : "")), keepSource: false)
    }
    func copy(file: CloudFile, to destination: String, accepted: ((URL) throws -> Void)? = nil) async throws {
        let source = try object(file.id)
        guard !source.key.isEmpty else { throw CloudError.message(L("iCloudy no copia buckets enteros. Copia las carpetas que contiene.")) }
        let folder = try object(destination)
        try await s3Relocate(file, from: source, to: S3Path(bucket: folder.bucket, key: folder.key + source.name + (source.isFolder ? "/" : "")), keepSource: true)
    }
    /// S3 has no bin: this deletes for good, and a folder with everything under it. The confirmation says so.
    func trash(file: CloudFile) async throws { try await s3Delete(try object(file.id)) }
    func publicLink(for file: CloudFile) async throws -> URL { try temporaryLink(for: file, lifetime: 24 * 3600) }
    func searchPage(term: String, cursor: String? = nil, filters: SearchFilters = SearchFilters(), referenceDate: Date = Date()) async throws -> SearchPage {
        try await s3Search(term: term, cursor: cursor)
    }
    func folderTrail(id: String) async throws -> [CloudFile] { try s3Trail(id: id) }
    func storageQuota() async throws -> StorageQuota {
        throw CloudError.message(L("S3 no informa del espacio disponible: no tiene un límite que consultar, se paga por lo que se guarda."))
    }
    func uploadFile(local: URL, parent: String, name: String, replacing: String?, cursor: inout UploadCheckpoint, save: (UploadCheckpoint) throws -> Void, progress: @escaping (Int64, Int64) -> Void) async throws -> UploadReceipt {
        try await s3Upload(local: local, parent: parent, name: name, replacing: replacing, cursor: &cursor, save: save, progress: progress)
    }
    func download(file: CloudFile, to destination: URL, exportMime: String?, maxBytes: Int64?, progress: @escaping (Int64, Int64) -> Void) async throws {
        try await s3Download(file: file, to: destination, maxBytes: maxBytes, progress: progress)
    }
    func currentMetadata(of file: CloudFile) async throws -> CloudFile? {
        let path = try object(file.id)
        guard !path.isFolder else { return nil }
        let current = try await head(path)
        if current.encrypted { opaqueChecksums.insert(file.id) }
        return current.file
    }
    func verifiableChecksum(of file: CloudFile) -> ContentHash? {
        opaqueChecksums.contains(file.id) ? nil : file.checksum
    }
    func abandonUploadSessions(urls: [URL], boxSessions: [String]) async {
        for raw in boxSessions {
            guard let upload = S3UploadSession(raw), let path = try? path(upload.objectID) else { continue }
            _ = try? await s3(S3Call(method: "DELETE", bucket: path.bucket, key: path.key, query: [("uploadId", upload.uploadID)]))
        }
    }
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
