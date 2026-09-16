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
        do { try await makeClient(.google).upload(local: link, parent: "root") { _ in }; XCTFail("Expected rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("simbólicos")) }
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
                XCTAssertEqual(request.value(forHTTPHeaderField: "X-Upload-Content-Length"), "5242897")
                return (200, ["Location": "https://upload.example/session"], Data())
            case 2:
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 0-5242879/5242897")
                return (308, ["Range": "bytes=0-5242879"], Data())
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 5242880-5242896/5242897")
                return (201, [:], Data(#"{"id":"created"}"#.utf8))
            }
        }
        var progress: [Double] = []
        try await makeClient(.google).upload(local: file, parent: "root") { progress.append($0) }
        XCTAssertEqual(count, 3)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress.count, 2)
    }

    @MainActor func testMicrosoftUploadUsesRenameAndDoesNotSendBearerToUploadHost() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("contents".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            if count == 1 {
                XCTAssertTrue(request.url!.path.hasSuffix("createUploadSession"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
                return (200, [:], Data(#"{"uploadUrl":"https://upload.example/session"}"#.utf8))
            }
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 0-7/8")
            return (201, [:], Data(#"{"id":"created"}"#.utf8))
        }
        try await makeClient(.microsoft).upload(local: file, parent: "root") { _ in }
        XCTAssertEqual(count, 2)
    }

    @MainActor private func makeClient(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil), session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
}
