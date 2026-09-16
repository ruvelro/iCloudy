import XCTest
@testable import iCloudy

@MainActor
final class ResumeTests: XCTestCase {
    private func client(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: Account(id: "test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "client", clientSecret: nil), session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func local() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 1_048_576).write(to: url)
        return url
    }
    private func checkpoint(_ local: URL) throws -> UploadCheckpoint {
        UploadCheckpoint(url: URL(string: "https://upload.example/session")!, offset: 0, total: 1_048_576, modified: try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }

    func testGoogleRecoveryUsesServerOffsetNotLocalOffset() async throws {
        let file = try local(); defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            if count == 1 {
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes */1048576")
                return (308, ["Range": "bytes=0-524287"], Data())
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 524288-1048575/1048576")
            return (200, [:], Data(#"{"id":"done"}"#.utf8))
        }
        var saved: [UploadCheckpoint] = []
        try await client(.google).resumableUpload(local: file, parent: "root", name: "test", replacing: nil, checkpoint: checkpoint(file), save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(count, 2); XCTAssertEqual(saved.first?.offset, 524_288); XCTAssertEqual(saved.last?.complete, true)
    }

    func testMicrosoftRecoveryDoesNotSendTokenToCapabilityURL() async throws {
        let file = try local(); defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if count == 1 {
                XCTAssertEqual(request.httpMethod, "GET")
                return (200, [:], Data(#"{"nextExpectedRanges":["327680-"]}"#.utf8))
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Range"), "bytes 327680-1048575/1048576")
            return (201, [:], Data(#"{"id":"done"}"#.utf8))
        }
        try await client(.microsoft).resumableUpload(local: file, parent: "root", name: "test", replacing: nil, checkpoint: checkpoint(file), save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(count, 2)
    }

    func testExpiredSessionNeverRecreatesFileAutomatically() async throws {
        let file = try local(); defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { _ in count += 1; return (404, [:], Data()) }
        do {
            try await client(.microsoft).resumableUpload(local: file, parent: "root", name: "test", replacing: nil, checkpoint: checkpoint(file), save: { _ in }, progress: { _, _ in })
            XCTFail("Expected an explicit recovery error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("caducado")) }
        XCTAssertEqual(count, 1)
    }

    func testGoogleReplacementUpdatesExistingFileInsteadOfCreating() async throws {
        let file = try local(); defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { request in
            count += 1
            if count == 1 {
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(request.url?.path, "/upload/drive/v3/files/existing-id")
                return (200, ["Location": "https://upload.example/session"], Data())
            }
            return (200, [:], Data(#"{"id":"existing-id"}"#.utf8))
        }
        try await client(.google).resumableUpload(local: file, parent: "root", name: "test", replacing: "existing-id", checkpoint: nil, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(count, 2)
    }

    func testModifiedSourceIsRejectedBeforeNetwork() async throws {
        let file = try local(); defer { try? FileManager.default.removeItem(at: file) }
        var cursor = try checkpoint(file); cursor.total = 100
        StubProtocol.handler = { _ in XCTFail("Must not upload changed source"); return (500, [:], Data()) }
        do {
            try await client(.google).resumableUpload(local: file, parent: "root", name: "test", replacing: nil, checkpoint: cursor, save: { _ in }, progress: { _, _ in })
            XCTFail("Expected changed source error")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cambiado")) }
    }
}
