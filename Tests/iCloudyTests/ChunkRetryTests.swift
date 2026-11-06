import XCTest
import CryptoKit
@testable import iCloudy

/// One block that fails for a transient reason is retried in place, instead of failing the upload session.
@MainActor
final class ChunkRetryTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    private func client(_ cloud: Cloud) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "retry-" + cloud.rawValue, cloud: cloud, name: "Prueba", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: [:])
        let api = CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
        (api.provider as CloudSession).blockRetryDelay = { _, _ in 0 }
        return api
    }
    private func source(_ payload: Data) throws -> (URL, UploadCheckpoint) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("retry-" + UUID().uuidString)
        try payload.write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return (url, UploadCheckpoint(total: Int64(payload.count), modified: try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate))
    }

    func testAGoogleBlockRefusedWith503ResumesFromWhatTheServerKept() async throws {
        let payload = Data((0..<1000).map { UInt8($0 % 251) })
        var ranges: [String] = []
        var refused = false
        StubProtocol.handler = { request in
            if request.url!.path.hasPrefix("/upload/drive") { return (200, ["Location": "https://www.googleapis.com/upload/session/1"], Data()) }
            let range = request.value(forHTTPHeaderField: "Content-Range") ?? ""
            ranges.append(range)
            if range == "bytes */1000" { return (308, ["Range": "bytes=0-399"], Data()) }   // the probe: 400 bytes got there
            if !refused { refused = true; return (503, [:], Data()) }
            let md5 = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
            return (200, [:], Data(#"{"id":"F1","md5Checksum":"\#(md5)","size":"1000"}"#.utf8))
        }
        let (local, checkpoint) = try source(payload)
        let receipt = try await client(.google).resumableUpload(local: local, parent: "root", name: "a.bin", replacing: nil, checkpoint: checkpoint,
                                                                save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(ranges, ["bytes 0-999/1000", "bytes */1000", "bytes 400-999/1000"], "Solo se reenvía lo que no llegó")
        XCTAssertEqual(receipt.remoteID, "F1")
        XCTAssertEqual(receipt.verification, .verified, "El hash cubre exactamente los bytes que el servidor confirmó")
    }

    func testAGraphBlockWhoseConnectionDroppedIsSentAgain() async throws {
        let payload = Data(repeating: 7, count: 300)
        var puts = 0, probes = 0
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("/createUploadSession") { return (200, [:], Data(#"{"uploadUrl":"https://up.example.com/s/1"}"#.utf8)) }
            if request.httpMethod == "GET" { probes += 1; return (200, [:], Data(#"{"nextExpectedRanges":["0-"]}"#.utf8)) }
            puts += 1
            if puts == 1 { throw URLError(.networkConnectionLost) }
            return (201, [:], Data(#"{"id":"G1"}"#.utf8))
        }
        let (local, checkpoint) = try source(payload)
        let receipt = try await client(.microsoft).resumableUpload(local: local, parent: "root", name: "a.bin", replacing: nil, checkpoint: checkpoint,
                                                                   save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "G1")
        XCTAssertEqual(puts, 2); XCTAssertEqual(probes, 1)
    }

    func testADropboxAppendRefusedOnceIsRepeatedAtTheSameOffset() async throws {
        let payload = Data(repeating: 1, count: 100)
        var appends: [String] = []
        StubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "start": return (200, [:], Data(#"{"session_id":"S"}"#.utf8))
            case "append_v2":
                appends.append(request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? "")
                return appends.count == 1 ? (500, [:], Data()) : (200, [:], Data("null".utf8))
            default: return (200, [:], Data(#"{"path_lower":"/a.bin"}"#.utf8))
            }
        }
        let (local, checkpoint) = try source(payload)
        let receipt = try await client(.dropbox).resumableUpload(local: local, parent: "root", name: "a.bin", replacing: nil, checkpoint: checkpoint,
                                                                 save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "/a.bin")
        XCTAssertEqual(appends.count, 2)
        XCTAssertEqual(appends[0], appends[1], "La misma petición, en el mismo punto")
    }

    func testOnlyTransientFailuresAreRepeatedAndOnlyAFewTimes() async throws {
        let session = client(.box).provider as CloudSession
        let response = { (status: Int) in HTTPURLResponse(url: URL(string: "https://x")!, statusCode: status, httpVersion: nil, headerFields: nil)! as URLResponse }
        var calls = 0
        _ = try await session.sendBlock { calls += 1; return (Data(), response(409)) }
        XCTAssertEqual(calls, 1, "Un 409 no es pasajero")
        calls = 0
        let (_, last) = try await session.sendBlock { calls += 1; return (Data(), response(503)) }
        XCTAssertEqual(calls, ResumableSessionUpload.attemptsPerBlock)
        XCTAssertEqual((last as? HTTPURLResponse)?.statusCode, 503, "La última respuesta sube tal cual para que la valide quien llama")
        calls = 0
        do { _ = try await session.sendBlock { calls += 1; throw URLError(.badServerResponse) }; XCTFail() } catch {}
        XCTAssertEqual(calls, 1)
    }
}
