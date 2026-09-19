import XCTest
import CryptoKit
@testable import iCloudy

@MainActor
final class ProviderTests: XCTestCase {
    private func client(_ cloud: Cloud, server: String? = nil) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil,
                              serverURL: server ?? (cloud == .webdav ? "https://dav.example.com/remote.php/dav/files/ana" : nil))
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func temporaryFile(_ payload: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try payload.write(to: url)
        return url
    }

    // MARK: - Dropbox

    func testDropboxListsByPathAndFollowsItsCursor() async throws {
        var bodies: [String] = []
        StubProtocol.handler = { request in
            bodies.append(requestBody(request))
            if bodies.count == 1 {
                XCTAssertEqual(request.url?.path, "/2/files/list_folder")
                return (200, [:], Data(#"{"entries":[{".tag":"folder","name":"Viaje","path_lower":"/viaje"}],"cursor":"c1","has_more":true}"#.utf8))
            }
            XCTAssertEqual(request.url?.path, "/2/files/list_folder/continue")
            return (200, [:], Data(#"{"entries":[{".tag":"file","name":"Nota.txt","path_lower":"/nota.txt","size":12,"server_modified":"2026-01-02T03:04:05Z"}],"has_more":false}"#.utf8))
        }
        var partial: [[CloudFile]] = []
        let files = try await client(.dropbox).list(parent: "root") { partial.append($0) }
        XCTAssertTrue(bodies[0].contains("\"path\":\"\""), "The root is the empty path: \(bodies[0])")
        XCTAssertTrue(bodies[1].contains("\"cursor\":\"c1\""))
        XCTAssertEqual(files.map(\.id), ["/viaje", "/nota.txt"], "Folders first, and the id is the path")
        XCTAssertEqual(files[0].isFolder, true)
        XCTAssertEqual(files[1].size, 12)
        XCTAssertEqual(files[1].mime, "text/plain")
        XCTAssertEqual(partial.count, 1, "The first page is shown before the second arrives")
    }

    func testDropboxWritesTargetTheRightPaths() async throws {
        var bodies: [String: String] = [:]
        StubProtocol.handler = { request in
            bodies[request.url!.path] = requestBody(request)
            return (200, [:], Data(#"{"metadata":{"name":"x","path_lower":"/destino/x"}}"#.utf8))
        }
        let api = client(.dropbox)
        let file = CloudFile(id: "/origen/foto.jpg", name: "Foto.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        _ = try await api.createFolder(name: "Nueva", parent: "/destino")
        XCTAssertTrue(bodies["/2/files/create_folder_v2"]!.contains("\"path\":\"\\/destino\\/Nueva\""), bodies["/2/files/create_folder_v2"]!)
        try await api.rename(file: file, name: "Otra.jpg")
        XCTAssertTrue(bodies["/2/files/move_v2"]!.contains("\"to_path\":\"\\/origen\\/Otra.jpg\""), "Renaming keeps the parent")
        try await api.move(file: file, to: "/destino")
        XCTAssertTrue(bodies["/2/files/move_v2"]!.contains("\"to_path\":\"\\/destino\\/Foto.jpg\""))
        try await api.trash(file: file)
        XCTAssertTrue(bodies["/2/files/delete_v2"]!.contains("\"path\":\"\\/origen\\/foto.jpg\""))
        XCTAssertEqual(api.dropboxTrail(id: "/uno/dos/tres").map(\.name), ["uno", "dos", "tres"], "Breadcrumbs need no request")
        XCTAssertEqual(api.dropboxTrail(id: "/uno/dos/tres").map(\.id), ["/uno", "/uno/dos", "/uno/dos/tres"])
    }

    func testDropboxUploadUsesSessionsAndVerifiesTheContentHash() async throws {
        let payload = Data(repeating: 7, count: 1024)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        // The documented hash: SHA-256 of each 4 MiB block, concatenated, hashed again.
        let expected = UploadHasher.hex(SHA256.hash(data: Data(SHA256.hash(data: payload))))
        var steps: [String] = []
        StubProtocol.handler = { request in
            steps.append(request.url!.path)
            XCTAssertEqual(request.url?.host, "content.dropboxapi.com")
            let argument = request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? ""
            switch request.url!.path {
            case "/2/files/upload_session/start":
                return (200, [:], Data(#"{"session_id":"s1"}"#.utf8))
            case "/2/files/upload_session/append_v2":
                XCTAssertTrue(argument.contains("\"session_id\":\"s1\""), argument)
                XCTAssertTrue(argument.contains("\"offset\":0"), argument)
                return (200, [:], Data())
            default:
                XCTAssertTrue(argument.contains("\"mode\":\"add\""), argument)
                XCTAssertTrue(argument.contains("\"offset\":1024"), argument)
                return (200, [:], Data(#"{"path_lower":"/destino/dato.bin","content_hash":"\#(expected)"}"#.utf8))
            }
        }
        var checkpoint = UploadCheckpoint(total: 1024, modified: try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        var saved: [UploadCheckpoint] = []
        let receipt = try await client(.dropbox).resumableUpload(local: file, parent: "/destino", name: "dato.bin", replacing: nil,
                                                                checkpoint: checkpoint, save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(steps, ["/2/files/upload_session/start", "/2/files/upload_session/append_v2", "/2/files/upload_session/finish"])
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertEqual(receipt.remoteID, "/destino/dato.bin")
        XCTAssertEqual(saved.first?.sessionID, "s1", "The session is checkpointed before any byte is sent")
        checkpoint = try XCTUnwrap(saved.last)
        XCTAssertTrue(checkpoint.complete)
    }

    func testDropboxUploadRejectsAMismatchedContentHash() async throws {
        let file = try temporaryFile(Data(repeating: 1, count: 16))
        defer { try? FileManager.default.removeItem(at: file) }
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("start") { return (200, [:], Data(#"{"session_id":"s1"}"#.utf8)) }
            if request.url!.path.hasSuffix("append_v2") { return (200, [:], Data()) }
            return (200, [:], Data(#"{"path_lower":"/x","content_hash":"0000000000000000000000000000000000000000000000000000000000000000"}"#.utf8))
        }
        let checkpoint = UploadCheckpoint(total: 16, modified: try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        do {
            _ = try await client(.dropbox).resumableUpload(local: file, parent: "/", name: "x", replacing: nil, checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
            XCTFail("A wrong content hash must fail loudly")
        } catch { XCTAssertTrue(error.localizedDescription.contains("suma de verificación"), error.localizedDescription) }
    }

    func testDropboxDownloadCarriesAnAsciiOnlyArgumentHeader() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var header = ""
        StubProtocol.handler = { request in
            header = request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? ""
            return (200, [:], Data("contenido".utf8))
        }
        let file = CloudFile(id: "/año/niño.txt", name: "niño.txt", mime: "text/plain", size: 9, modified: nil, webURL: nil, isFolder: false)
        try await client(.dropbox).download(file: file, to: destination)
        XCTAssertTrue(header.allSatisfy(\.isASCII), "HTTP headers cannot carry raw UTF-8: \(header)")
        XCTAssertTrue(header.contains("\\u00f1"), "Non-ASCII must be escaped: \(header)")
        XCTAssertEqual(try Data(contentsOf: destination), Data("contenido".utf8))
    }

    // MARK: - Box

    func testBoxPaginatesByOffsetAndBuildsTrailFromPathCollection() async throws {
        var urls: [URL] = []
        StubProtocol.handler = { request in
            urls.append(request.url!)
            if request.url!.path.hasSuffix("/items") {
                let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!
                if offset == "0" { return (200, [:], Data(#"{"total_count":2,"entries":[{"type":"folder","id":"11","name":"Fotos"}]}"#.utf8)) }
                return (200, [:], Data(#"{"total_count":2,"entries":[{"type":"file","id":"12","name":"a.pdf","size":9}]}"#.utf8))
            }
            return (200, [:], Data(#"{"id":"11","name":"Fotos","path_collection":{"entries":[{"type":"folder","id":"0","name":"All Files"},{"type":"folder","id":"5","name":"Trabajo"}]}}"#.utf8))
        }
        let api = client(.box)
        let files = try await api.list(parent: "root")
        XCTAssertEqual(urls[0].path, "/2.0/folders/0/items", "iCloudy's root maps to Box's folder 0")
        XCTAssertEqual(files.map(\.id), ["11", "12"])
        let trail = try await api.folderTrail(id: "11")
        XCTAssertEqual(trail.map(\.name), ["Trabajo", "Fotos"], "The root entry is dropped and the folder itself closes the trail")
    }

    func testBoxChoosesSimpleOrChunkedUploadAndSendsDigests() async throws {
        let payload = Data(repeating: 3, count: 1024)
        let sha1 = UploadHasher.hex(Insecure.SHA1.hash(data: payload))
        let small = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: small) }
        var contentType = "", digest = "", path = ""
        StubProtocol.handler = { request in
            path = request.url!.path; contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
            digest = request.value(forHTTPHeaderField: "content-md5") ?? ""
            return (201, [:], Data(#"{"entries":[{"id":"99","sha1":"\#(sha1)"}]}"#.utf8))
        }
        let checkpoint = UploadCheckpoint(total: 1024, modified: try small.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let receipt = try await client(.box).resumableUpload(local: small, parent: "5", name: "a.bin", replacing: nil, checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(path, "/api/2.0/files/content", "Under 20 MB Box refuses upload sessions")
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        XCTAssertEqual(digest, sha1, "The single-shot endpoint takes the SHA-1 in content-md5, in hex")
        XCTAssertEqual(receipt.remoteID, "99")
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertGreaterThan(CloudAPI.boxSessionThreshold, 0)
    }

    func testBoxOnlyCountsAnUploadAsVerifiedWhenItsHashMatches() async throws {
        // A stored sha1 used to be enough for "verified" without ever being compared. It has to match the bytes sent.
        let small = try temporaryFile(Data(repeating: 3, count: 1024))
        defer { try? FileManager.default.removeItem(at: small) }
        let checkpoint = UploadCheckpoint(total: 1024, modified: try small.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        StubProtocol.handler = { _ in (201, [:], Data(#"{"entries":[{"id":"99","sha1":"0000000000000000000000000000000000000000"}]}"#.utf8)) }
        do {
            _ = try await client(.box).resumableUpload(local: small, parent: "5", name: "a.bin", replacing: nil, checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
            XCTFail("A different hash must fail loudly")
        } catch { XCTAssertTrue(error.localizedDescription.contains("suma de verificación"), error.localizedDescription) }
        StubProtocol.handler = { _ in (201, [:], Data(#"{"entries":[{"id":"99"}]}"#.utf8)) }
        let receipt = try await client(.box).resumableUpload(local: small, parent: "5", name: "a.bin", replacing: nil, checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .unavailable, "No hash from Box, nothing to compare")
    }

    func testBoxSessionCommitsCarryTheWholeFileDigestEvenWhenResumed() async throws {
        // Box refuses a commit without the digest of the whole file. A resumed session did not see the earlier
        // parts leave, so it hashes them again from the local file, which also lets the upload be verified.
        let size = Int(CloudAPI.boxSessionThreshold) + 1024
        var payload = Data(count: size)
        for index in stride(from: 0, to: size, by: 4099) { payload[index] = UInt8(index % 251) }
        let sha1 = UploadHasher.hex(Insecure.SHA1.hash(data: payload))
        let large = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: large) }
        let partSize = 8 * 1024 * 1024
        var parts: [String] = [], commitDigest: String?, ranges: [String] = []
        StubProtocol.handler = { request in
            let path = request.url!.path
            if path == "/api/2.0/files/upload_sessions" {
                return (201, [:], Data(#"{"id":"s1","part_size":\#(partSize)}"#.utf8))
            }
            if path.hasSuffix("/commit") {
                commitDigest = request.value(forHTTPHeaderField: "Digest")
                let body = (try? JSONSerialization.jsonObject(with: requestData(request))) as? [String: Any]
                parts = (body?["parts"] as? [[String: Any]])?.map { "\($0)" } ?? []
                return (201, [:], Data(#"{"entries":[{"id":"77","sha1":"\#(sha1)"}]}"#.utf8))
            }
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            ranges.append(range)
            let offset = range.split(separator: " ").last?.split(separator: "-").first ?? ""
            return (200, [:], Data(#"{"part":{"part_id":"p\#(offset)","offset":\#(offset),"size":1}}"#.utf8))
        }
        let stamp = try large.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let fresh = try await client(.box).resumableUpload(local: large, parent: "5", name: "big.bin", replacing: nil,
                                                          checkpoint: UploadCheckpoint(total: Int64(size), modified: stamp), save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(ranges.count, 3, "Three parts of 8 MiB")
        XCTAssertEqual(commitDigest, "sha=" + Data(Insecure.SHA1.hash(data: payload)).base64EncodedString())
        XCTAssertEqual(fresh.verification, .verified)
        XCTAssertEqual(fresh.remoteID, "77")
        XCTAssertFalse(parts.isEmpty)

        // The same upload, interrupted after the first part and resumed from the checkpoint.
        ranges = []; commitDigest = nil
        var resumed = UploadCheckpoint(total: Int64(size), modified: stamp)
        resumed.sessionID = "s1"; resumed.chunkSize = Int64(partSize); resumed.offset = Int64(partSize)
        resumed.parts = [#"{"part_id":"p0","offset":0,"size":8388608}"#]
        let receipt = try await client(.box).resumableUpload(local: large, parent: "5", name: "big.bin", replacing: nil,
                                                            checkpoint: resumed, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(ranges.count, 2, "Only the parts after the checkpoint travel again")
        XCTAssertEqual(commitDigest, "sha=" + Data(Insecure.SHA1.hash(data: payload)).base64EncodedString(), "The digest covers the whole file, resumed or not")
        XCTAssertEqual(receipt.verification, .verified)
    }

    // MARK: - WebDAV

    func testWebDAVParsesMultistatusAndSkipsTheFolderItself() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/ana/Fotos/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/ana/Fotos/ni%C3%B1o.jpg</d:href>
            <d:propstat><d:prop><d:displayname>niño.jpg</d:displayname><d:getcontentlength>2048</d:getcontentlength>
            <d:getlastmodified>Mon, 12 Jan 2026 10:00:00 GMT</d:getlastmodified><d:getcontenttype>image/jpeg</d:getcontenttype>
            <d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            <d:propstat><d:prop><d:quota-used-bytes/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/ana/Fotos/Viaje/</d:href>
            <d:propstat><d:prop><d:displayname>Viaje</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let entries = WebDAVEntry.parse(xml, basePath: "/remote.php/dav/files/ana")
        XCTAssertEqual(entries.map(\.path), ["/Fotos", "/Fotos/niño.jpg", "/Fotos/Viaje"], "Hrefs are percent-decoded and made relative")
        let photo = entries[1].file
        XCTAssertEqual(photo.name, "niño.jpg")
        XCTAssertEqual(photo.size, 2048)
        XCTAssertEqual(photo.mime, "image/jpeg")
        XCTAssertFalse(photo.isFolder)
        XCTAssertEqual(photo.modified, Date(timeIntervalSince1970: 1_768_212_000))
        XCTAssertTrue(entries[2].file.isFolder)
        XCTAssertNil(entries[1].quotaUsed, "A 404 propstat must not leak into the item")
    }

    func testWebDAVListFiltersTheRequestedFolderAndBuildsEncodedURLs() async throws {
        var url: URL?
        var depth = ""
        StubProtocol.handler = { request in
            url = request.url; depth = request.value(forHTTPHeaderField: "Depth") ?? ""
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            return (207, [:], Data("""
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
            <d:response><d:href>/remote.php/dav/files/ana/Fotos</d:href><d:propstat><d:prop>
            <d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/remote.php/dav/files/ana/Fotos/a.txt</d:href><d:propstat><d:prop>
            <d:displayname>a.txt</d:displayname><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>
            """.utf8))
        }
        let files = try await client(.webdav).list(parent: "/Fotos")
        XCTAssertEqual(depth, "1")
        XCTAssertEqual(url?.path, "/remote.php/dav/files/ana/Fotos")
        XCTAssertEqual(files.map(\.name), ["a.txt"], "The folder itself is not one of its own children")
    }

    func testWebDAVMoveAndDeleteUseTheRightVerbsAndHeaders() async throws {
        var seen: [(String, String?)] = []
        StubProtocol.handler = { request in
            seen.append((request.httpMethod ?? "", request.value(forHTTPHeaderField: "Destination")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic test-token", "WebDAV authenticates with Basic")
            return (204, [:], Data())
        }
        let api = client(.webdav)
        let file = CloudFile(id: "/Fotos/niño.jpg", name: "niño.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.move(file: file, to: "/Destino")
        XCTAssertEqual(seen.last?.0, "MOVE")
        XCTAssertEqual(seen.last?.1, "https://dav.example.com/remote.php/dav/files/ana/Destino/ni%C3%B1o.jpg")
        try await api.copy(file: file, to: "/Destino")
        XCTAssertEqual(seen.last?.0, "COPY")
        try await api.rename(file: file, name: "gato.jpg")
        XCTAssertEqual(seen.last?.1, "https://dav.example.com/remote.php/dav/files/ana/Fotos/gato.jpg", "Renaming keeps the parent")
        try await api.trash(file: file)
        XCTAssertEqual(seen.last?.0, "DELETE")
        XCTAssertEqual(api.webdavTrail(id: "/uno/dos").map(\.id), ["/uno", "/uno/dos"])
    }

    func testWebDAVRejectsSearchAndPublicLinksInsteadOfPretending() async throws {
        let api = client(.webdav)
        let file = CloudFile(id: "/a.txt", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        StubProtocol.handler = { _ in XCTFail("Unsupported features must not reach the network"); return (500, [:], Data()) }
        do { _ = try await api.searchPage(term: "x"); XCTFail("Expected an explicit refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("búsqueda"), error.localizedDescription) }
        do { _ = try await api.publicLink(for: file); XCTFail("Expected an explicit refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("enlaces públicos"), error.localizedDescription) }
    }

    // MARK: - Capabilities and sign-in

    func testCapabilitiesDescribeWhatEachProviderCanDo() {
        XCTAssertTrue(Cloud.google.capabilities.exportsDocuments)
        XCTAssertFalse(Cloud.dropbox.capabilities.exportsDocuments)
        XCTAssertTrue(Cloud.dropbox.capabilities.reversibleTrash, "Dropbox keeps deleted files recoverable")
        XCTAssertFalse(Cloud.webdav.capabilities.reversibleTrash, "Plain WebDAV deletes for good")
        XCTAssertFalse(Cloud.webdav.capabilities.search)
        XCTAssertFalse(Cloud.webdav.capabilities.oauth)
        XCTAssertFalse(Cloud.box.capabilities.recents)
        XCTAssertTrue(Cloud.microsoft.capabilities.sharedWithMe)
        XCTAssertEqual(Cloud.box.rootAlias, "0")
        XCTAssertEqual(Cloud.dropbox.rootAlias, "")
        XCTAssertEqual(Cloud.webdav.authorizationScheme, "Basic")
        XCTAssertEqual(Cloud.google.authorizationScheme, "Bearer")
    }

    func testAuthorizationURLsMatchEachProvidersEndpoint() {
        let dropbox = OAuthRequest.authorizationURL(cloud: .dropbox, clientID: "key", state: "s", challenge: "c")
        let query = URLComponents(url: dropbox, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(dropbox.host, "www.dropbox.com")
        XCTAssertEqual(query.first { $0.name == "token_access_type" }?.value, "offline", "Without this Dropbox returns no refresh token")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNil(query.first { $0.name == "prompt" }, "Dropbox rejects Google's prompt parameter")
        let box = OAuthRequest.authorizationURL(cloud: .box, clientID: "key", state: "s", challenge: "c")
        XCTAssertEqual(box.host, "account.box.com")
        XCTAssertEqual(URLComponents(url: box, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }?.value, OAuthRequest.redirectURI)
    }

    func testConfigurationValidatesEachProviderAndRefusesWebDAV() throws {
        let config = OAuthConfiguration(googleClientID: "1234567890-example.apps.googleusercontent.com", googleDesktopClientSecret: "g",
                                        microsoftClientID: "12345678-1234-1234-1234-123456789012",
                                        dropboxAppKey: "abcdefghij1234", boxClientID: String(repeating: "b", count: 32), boxClientSecret: "s")
        XCTAssertEqual(try config.client(for: .dropbox).secret, "", "Dropbox desktop apps use PKCE without a secret")
        XCTAssertEqual(try config.client(for: .box).secret, "s")
        XCTAssertThrowsError(try config.client(for: .webdav)) { XCTAssertTrue($0.localizedDescription.contains("WebDAV")) }
        XCTAssertThrowsError(try OAuthConfiguration(dropboxAppKey: "corto").client(for: .dropbox))
        // A plist written before these providers existed must still load.
        let legacy = Data(#"<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>googleClientID</key><string>x</string><key>googleDesktopClientSecret</key><string>y</string><key>microsoftClientID</key><string>z</string></dict></plist>"#.utf8)
        let decoded = try PropertyListDecoder().decode(OAuthConfiguration.self, from: legacy)
        XCTAssertEqual(decoded.googleClientID, "x")
        XCTAssertEqual(decoded.dropboxAppKey, "")
    }

    func testWebDAVSignInValidatesTheServerBeforeStoringAnything() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let oauth = OAuth(session: URLSession(configuration: config)) { _ in XCTFail("WebDAV must not open a browser"); return false }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("ana:secreta".utf8).base64EncodedString())
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8))
        }
        let (account, credential) = try await oauth.signInWebDAV(server: "dav.example.com/remote.php/dav/files/ana/", username: "ana", password: "secreta")
        XCTAssertEqual(account.cloud, .webdav)
        XCTAssertEqual(account.serverURL, "https://dav.example.com/remote.php/dav/files/ana", "Scheme added and trailing slash removed")
        XCTAssertEqual(account.id, "webdav:dav.example.com/remote.php/dav/files/ana#ana")
        XCTAssertEqual(credential.accessToken, Data("ana:secreta".utf8).base64EncodedString())
        XCTAssertGreaterThan(credential.expires, Date(timeIntervalSinceNow: 86_400), "Basic credentials do not expire on their own")

        StubProtocol.handler = { _ in (401, [:], Data()) }
        do { _ = try await oauth.signInWebDAV(server: "https://dav.example.com", username: "ana", password: "mala"); XCTFail("Expected a rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rechazó"), error.localizedDescription) }
        StubProtocol.handler = { _ in XCTFail("A malformed address must not be contacted"); return (500, [:], Data()) }
        do { _ = try await oauth.signInWebDAV(server: "no es una url", username: "a", password: "b"); XCTFail("Expected a rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("dirección"), error.localizedDescription) }
    }

    func testCredentialsTypedIntoTheWebDAVAddressAreUsedButNeverStored() async throws {
        // Password managers hand out `https://ana:secreta@nas/dav`. The address lives in accounts.json, outside the
        // Keychain, so what rides in it is stripped and treated as the credentials it is.
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let oauth = OAuth(session: URLSession(configuration: config)) { _ in false }
        var authorization: String?
        StubProtocol.handler = { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertNil(request.url?.user, "The request itself carries no userinfo either")
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8))
        }
        let (account, credential) = try await oauth.signInWebDAV(server: "https://ana:secr%40ta@dav.example.com/dav/", username: "", password: "")
        XCTAssertEqual(account.serverURL, "https://dav.example.com/dav")
        XCTAssertEqual(account.id, "webdav:dav.example.com/dav#ana")
        XCTAssertEqual(credential.accessToken, Data("ana:secr@ta".utf8).base64EncodedString(), "Percent-decoded, as typed")
        XCTAssertEqual(authorization, "Basic " + Data("ana:secr@ta".utf8).base64EncodedString())

        // What the form says wins over what the address carries.
        let (typed, typedCredential) = try await oauth.signInWebDAV(server: "https://otra:x@dav.example.com/dav", username: "ana", password: "secreta")
        XCTAssertEqual(typed.serverURL, "https://dav.example.com/dav")
        XCTAssertEqual(typedCredential.accessToken, Data("ana:secreta".utf8).base64EncodedString())
    }
}
