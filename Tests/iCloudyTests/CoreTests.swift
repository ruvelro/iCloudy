import XCTest
@testable import iCloudy

final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

/// URLProtocol receives POST bodies as a stream, not as `httpBody`.
func requestBody(_ request: URLRequest) -> String {
    if let data = request.httpBody { return String(decoding: data, as: UTF8.self) }
    guard let stream = request.httpBodyStream else { return "" }
    stream.open(); defer { stream.close() }
    var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
        let read = stream.read(&buffer, maxLength: buffer.count)
        guard read > 0 else { break }
        data.append(buffer, count: read)
    }
    return String(decoding: data, as: UTF8.self)
}

final class CoreTests: XCTestCase {
    func testFormEncodingDoesNotTurnPlusIntoSpace() {
        let result = String(data: HTTP.form(["code": "a+b /&=ñ"]), encoding: .utf8)
        XCTAssertEqual(result, "code=a%2Bb%20%2F%26%3D%C3%B1")
    }

    @MainActor func testPKCEAgainstRFC7636() {
        XCTAssertEqual(OAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testDownloadNamesCannotEscapeDestinationOrOverwrite() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("report.pdf")
        try Data("original".utf8).write(to: original)
        XCTAssertEqual(FileNames.available(in: folder, name: "report.pdf").lastPathComponent, "report (2).pdf")
        XCTAssertEqual(FileNames.available(in: folder, name: "../outside").deletingLastPathComponent().path, folder.path)
        XCTAssertEqual(FileNames.safe(".."), "archivo")
        XCTAssertEqual(try String(contentsOf: original), "original")
    }

    @MainActor func testProviderMappingsHandleNativeDocumentsAndRemoteFolders() {
        let document = CloudAPI.googleFile(["id": "g1", "name": "Informe", "mimeType": "application/vnd.google-apps.document", "modifiedTime": "2026-09-15T12:00:00.000Z"])
        XCTAssertTrue(document!.isGoogleDocument)
        XCTAssertFalse(document!.isFolder)
        XCTAssertEqual(document!.exportOptions.map(\.ext), ["pdf", "docx"])
        XCTAssertNotNil(document!.modified)
        let remote = CloudAPI.microsoftFile(["id": "r1", "name": "Compartido", "folder": [:], "remoteItem": ["id": "other-drive"]])
        XCTAssertFalse(remote!.isFolder, "Remote folders cannot be navigated using the current drive ID")
        XCTAssertTrue(remote!.isGoogleDocument)
        XCTAssertNil(CloudAPI.googleFile(["name": "missing-id"]))
    }

    @MainActor func testGoogleListingFollowsPagesAndSortsFoldersFirst() async throws {
        var requests = 0
        StubProtocol.handler = { request in
            requests += 1
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            XCTAssertEqual(query.first { $0.name == "q" }?.value, "'root' in parents and trashed = false")
            if requests == 1 { return (200, [:], Data(#"{"nextPageToken":"second","files":[{"id":"a","name":"a.txt","size":"42","mimeType":"text/plain"}]}"#.utf8)) }
            XCTAssertEqual(query.first { $0.name == "pageToken" }?.value, "second")
            return (200, [:], Data(#"{"files":[{"id":"z","name":"Z folder","mimeType":"application/vnd.google-apps.folder"}]}"#.utf8))
        }
        let files = try await makeClient(.google).list(parent: "root")
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(files.map(\.id), ["z", "a"])
        XCTAssertEqual(files.last?.size, 42)
    }

    @MainActor func testRecentAndSharedCollectionsUseProviderLists() async throws {
        var urls: [URL] = []
        StubProtocol.handler = { request in
            urls.append(request.url!)
            if request.url!.host == "www.googleapis.com" { return (200, [:], Data(#"{"files":[{"id":"r1","name":"Reciente.pdf","mimeType":"application/pdf"}]}"#.utf8)) }
            return (200, [:], Data(#"{"value":[{"id":"s1","name":"Compartida","folder":{},"remoteItem":{"id":"x"},"webUrl":"https://1drv.ms/f/s1"}]}"#.utf8))
        }
        let google = try await makeClient(.google)
        let recent = try await google.list(parent: Collection.recent.rootID)
        XCTAssertEqual(recent.map(\.id), ["r1"])
        var query = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "orderBy" }?.value, "viewedByMeTime desc")
        XCTAssertTrue(query.first { $0.name == "q" }!.value!.contains("mimeType != 'application/vnd.google-apps.folder'"))
        _ = try await google.list(parent: Collection.shared.rootID)
        query = URLComponents(url: urls[1], resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "q" }?.value, "sharedWithMe = true and trashed = false")

        let microsoft = try await makeClient(.microsoft)
        _ = try await microsoft.list(parent: Collection.recent.rootID)
        XCTAssertEqual(urls[2].path, "/v1.0/me/drive/recent")
        let shared = try await microsoft.list(parent: Collection.shared.rootID)
        XCTAssertEqual(urls[3].path, "/v1.0/me/drive/sharedWithMe")
        XCTAssertEqual(shared.first?.isGoogleDocument, true, "Remote items stay browser links in this version")
        XCTAssertFalse(urls.contains { $0.path.contains("items/recent") || $0.path.contains("items/sharedWithMe") }, "Virtual roots must never be treated as item ids")
    }

    @MainActor func testDemoRecentListsFilesNewestFirstAndSharedIsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = try DemoStore(directory: root)
        let newest = try demo.add(name: "z-nuevo.txt", parent: "root", content: Data("x".utf8))
        let recent = try demo.list(Collection.recent.rootID)
        XCTAssertEqual(recent.first?.id, newest)
        XCTAssertFalse(recent.contains { $0.isFolder })
        XCTAssertTrue(try demo.list(Collection.shared.rootID).isEmpty)
    }

    @MainActor func testMicrosoftRejectsForeignPaginationHost() async throws {
        StubProtocol.handler = { _ in (200, [:], Data(#"{"value":[],"@odata.nextLink":"https://untrusted.example/collect"}"#.utf8)) }
        do {
            _ = try await makeClient(.microsoft).list(parent: "root")
            XCTFail("Must reject an untrusted next link before sending credentials")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Paginación")) }
    }

    @MainActor func testSymlinkUploadIsRejectedBeforeNetworkCall() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("loop")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        StubProtocol.handler = { _ in XCTFail("Must not contact the cloud for symlinks"); return (500, [:], Data()) }
        do {
            try await makeClient(.google).resumableUpload(local: link, parent: "root", name: "loop", replacing: nil, checkpoint: nil, save: { _ in }, progress: { _, _ in })
            XCTFail("Expected rejection")
        } catch { XCTAssertTrue(error.localizedDescription.contains("simbólicos")) }
    }

    @MainActor func testChunkedGoogleUploadRequiresServerAcknowledgement() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 5 * 1024 * 1024 + 17).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            switch count {
            case 1:
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Upload-Content-Length"), "5242897")
                return (200, ["Location": "https://upload.example/session"], Data())
            case 2:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "The session URI is the credential")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 0-5242879/5242897")
                return (308, ["Range": "bytes=0-5242879"], Data())
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 5242880-5242896/5242897")
                return (201, [:], Data(#"{"id":"created"}"#.utf8))
            }
        }
        var offsets: [Int64] = []
        var saved: [UploadCheckpoint] = []
        try await makeClient(.google).resumableUpload(local: file, parent: "root", name: "big.bin", replacing: nil, checkpoint: nil, save: { saved.append($0) }, progress: { bytes, _ in offsets.append(bytes) })
        XCTAssertEqual(count, 3)
        XCTAssertEqual(offsets.last, 5_242_897)
        XCTAssertEqual(saved.first?.url?.absoluteString, "https://upload.example/session", "The session is checkpointed before any byte is sent")
        XCTAssertEqual(saved.map(\.offset), [0, 5_242_880, 5_242_897])
        XCTAssertEqual(saved.last?.complete, true)
    }

    @MainActor func testMicrosoftUploadFailsOnConflictAndDoesNotSendBearerToUploadHost() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("contents".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            if count == 1 {
                XCTAssertTrue(request.url!.path.hasSuffix("createUploadSession"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                XCTAssertTrue(requestBody(request).contains(#""@microsoft.graph.conflictBehavior":"fail""#), "The queue resolves conflicts itself; the server must not rename silently")
                return (200, [:], Data(#"{"uploadUrl":"https://upload.example/session"}"#.utf8))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 0-7/8")
            return (201, [:], Data(#"{"id":"created"}"#.utf8))
        }
        try await makeClient(.microsoft).resumableUpload(local: file, parent: "root", name: "contents.txt", replacing: nil, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(count, 2)
    }

    @MainActor func testDownloadErrorBodyReachesTheUser() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        StubProtocol.handler = { _ in (403, [:], Data(#"{"error":{"code":403,"message":"This file is too large to be exported."}}"#.utf8)) }
        let file = CloudFile(id: "doc", name: "Informe", mime: "application/vnd.google-apps.document", size: nil, modified: nil, webURL: nil, isFolder: false)
        do {
            try await makeClient(.google).download(file: file, to: destination, exportMime: "application/pdf")
            XCTFail("Expected the export to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("too large"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    @MainActor func testPublicLinkGrantsAnyoneReadOnlyAndReturnsTheProviderLink() async throws {
        let file = CloudFile(id: "f1", name: "Informe.pdf", mime: "application/pdf", size: 10, modified: nil, webURL: URL(string: "https://drive.google.com/file/d/f1/view"), isFolder: false)
        var calls: [String] = []
        StubProtocol.handler = { request in
            calls.append("\(request.httpMethod ?? "") \(request.url!.path)")
            if request.url!.path.hasSuffix("/permissions") {
                XCTAssertTrue(requestBody(request).contains(#""role":"reader""#))
                XCTAssertTrue(requestBody(request).contains(#""type":"anyone""#))
                return (200, [:], Data(#"{"id":"anyoneWithLink"}"#.utf8))
            }
            return (200, [:], Data(#"{"webViewLink":"https://drive.google.com/file/d/f1/view?usp=sharing"}"#.utf8))
        }
        let google = try await makeClient(.google).publicLink(for: file)
        XCTAssertEqual(google.absoluteString, "https://drive.google.com/file/d/f1/view?usp=sharing")
        XCTAssertEqual(calls, ["POST /drive/v3/files/f1/permissions", "GET /drive/v3/files/f1"])

        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/items/f1/createLink"))
            XCTAssertTrue(requestBody(request).contains(#""scope":"anonymous""#))
            XCTAssertTrue(requestBody(request).contains(#""type":"view""#))
            return (201, [:], Data(#"{"link":{"type":"view","scope":"anonymous","webUrl":"https://1drv.ms/x/abc"}}"#.utf8))
        }
        let microsoft = try await makeClient(.microsoft).publicLink(for: file)
        XCTAssertEqual(microsoft.absoluteString, "https://1drv.ms/x/abc")
    }

    func testOneDriveNameRulesAreStricterThanDrive() {
        XCTAssertNil(FileNames.problem(with: "Informe: final?", for: .google))
        XCTAssertNotNil(FileNames.problem(with: "Informe: final?", for: .microsoft))
        XCTAssertNotNil(FileNames.problem(with: "a/b", for: .google))
        XCTAssertNotNil(FileNames.problem(with: "", for: .google))
        for bad in [" leading", "trailing ", "dot.", "CON", "com1.txt", "desktop.ini", "~$lock.docx", "x_vti_y", String(repeating: "a", count: 256)] {
            XCTAssertNotNil(FileNames.problem(with: bad, for: .microsoft), bad)
        }
        for good in ["Informe final.pdf", "Fotos 2026", "console.log", "ñandú (2).txt", ".ocultos"] {
            XCTAssertNil(FileNames.problem(with: good, for: .microsoft), good)
        }
    }

    func testErrorDetailsUnderstandBothProviderShapes() {
        let oauth = HTTP.errorDetails(Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8))
        XCTAssertEqual(oauth.code, "invalid_grant")
        XCTAssertEqual(oauth.message, "Token has been expired or revoked.")
        let graph = HTTP.errorDetails(Data(#"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired."}}"#.utf8))
        XCTAssertEqual(graph.code, "InvalidAuthenticationToken")
        XCTAssertEqual(graph.message, "Access token has expired.")
        let drive = HTTP.errorDetails(Data(#"{"error":{"code":404,"status":"NOT_FOUND","message":"File not found"}}"#.utf8))
        XCTAssertEqual(drive.code, "NOT_FOUND")
        XCTAssertEqual(HTTP.errorDetails(Data("nonsense".utf8)).message, nil)
    }

    @MainActor private func makeClient(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil), session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
}
