import XCTest
@testable import iCloudy

/// Nextcloud's chunked upload v2 over the HTTP stub: the collection, the numbered chunks with their headers, the
/// final MOVE, and a resumed upload that sends only the chunks the server had not confirmed.
@MainActor
final class NextcloudChunkingTests: XCTestCase {
    private let server = "https://nube.example.com/remote.php/dav/files/ana"

    private func client(nextcloud: Bool = true) -> (CloudAPI, WebDAVProvider) {
        let api = makeStubbedClient(.webdav, server: server, options: nextcloud ? ["flavor": "nextcloud"] : [:])
        let provider = api.provider as! WebDAVProvider
        provider.chunkedThreshold = 10
        provider.chunkOverride = 4
        provider.blockRetryDelay = { _, _ in 0 }
        return (api, provider)
    }
    private func source(_ text: String) throws -> URL {
        let url = try temporaryRoot().appendingPathComponent("grande.bin")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testAChunkedUploadCreatesTheCollectionSendsNumberedChunksAndMovesThemIntoPlace() async throws {
        let log = Box<[String]>([])
        let chunks = Box<[String: String]>([:])
        StubProtocol.handler = { request in
            let path = request.url!.path, method = request.httpMethod ?? ""
            log.value.append(method + " " + path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Destination"), "https://nube.example.com/remote.php/dav/files/ana/Docs/grande.bin",
                           "\(method) names the final file")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OC-Total-Length"), "10")
            switch method {
            case "MKCOL": XCTAssertTrue(path.hasPrefix("/remote.php/dav/uploads/ana/icloudy-")); return (201, [:], Data())
            case "PUT": chunks.value[String(path.split(separator: "/").last!)] = requestBody(request); return (201, [:], Data())
            case "MOVE":
                XCTAssertTrue(path.hasSuffix("/.file"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Overwrite"), "F", "A new file never clobbers one already there")
                return (201, [:], Data())
            default: XCTFail("Unexpected \(method) \(path)"); return (500, [:], Data())
            }
        }
        let (api, _) = client()
        var saved: UploadCheckpoint?
        let receipt = try await api.resumableUpload(local: try source("0123456789"), parent: "/Docs", name: "grande.bin", replacing: nil,
                                                    checkpoint: nil, save: { saved = $0 }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "/Docs/grande.bin")
        XCTAssertEqual(chunks.value, ["00001": "0123", "00002": "4567", "00003": "89"])
        XCTAssertEqual(log.value.map { $0.split(separator: " ")[0] }, ["MKCOL", "PUT", "PUT", "PUT", "MOVE"])
        XCTAssertEqual(saved?.complete, true)
        XCTAssertNil(saved?.url, "The finished session is forgotten")
    }

    func testAResumedUploadSendsOnlyWhatTheServerHasNotConfirmed() async throws {
        let failSecond = Box(true)
        let puts = Box<[String]>([])
        StubProtocol.handler = { request in
            let path = request.url!.path, method = request.httpMethod ?? ""
            switch method {
            case "MKCOL": return (201, [:], Data())
            case "PROPFIND":
                XCTAssertTrue(path.hasPrefix("/remote.php/dav/uploads/ana/"), "A resumed upload checks its collection first")
                return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>"#.utf8))
            case "PUT":
                let name = String(path.split(separator: "/").last!)
                if name == "00002", failSecond.value { failSecond.value = false; return (403, [:], Data()) }
                puts.value.append(name); return (201, [:], Data())
            case "MOVE": return (201, [:], Data())
            default: XCTFail("Unexpected \(method) \(path)"); return (500, [:], Data())
            }
        }
        let (api, _) = client()
        let local = try source("0123456789")
        var saved: UploadCheckpoint?
        do {
            _ = try await api.resumableUpload(local: local, parent: "/Docs", name: "grande.bin", replacing: nil, checkpoint: nil,
                                              save: { saved = $0 }, progress: { _, _ in })
            XCTFail("The refused chunk stops the first attempt")
        } catch {}
        XCTAssertEqual(saved?.offset, 4, "Only the first chunk was confirmed")
        XCTAssertNotNil(saved?.url)
        _ = try await api.resumableUpload(local: local, parent: "/Docs", name: "grande.bin", replacing: nil, checkpoint: saved,
                                          save: { saved = $0 }, progress: { _, _ in })
        XCTAssertEqual(puts.value, ["00001", "00002", "00003"], "Chunk 1 went once; the retry started at chunk 2")
        XCTAssertEqual(saved?.complete, true)
    }

    func testAnExpiredCollectionStartsAgainAndCancellingDeletesIt() async throws {
        let created = Box(0)
        let deleted = Box<[String]>([])
        StubProtocol.handler = { request in
            switch request.httpMethod ?? "" {
            case "PROPFIND": return (404, [:], Data())
            case "MKCOL": created.value += 1; return (201, [:], Data())
            case "DELETE": deleted.value.append(request.url!.path); return (204, [:], Data())
            case "PUT", "MOVE": return (201, [:], Data())
            default: return (500, [:], Data())
            }
        }
        let (api, _) = client()
        let local = try source("0123456789")
        let stamp = try UploadSourceStamp(local)
        var stale = UploadCheckpoint(url: URL(string: "https://nube.example.com/remote.php/dav/uploads/ana/icloudy-old")!, offset: 4, total: 10,
                                     modified: try local.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        stale.chunkSize = 4; stale.sourceStamp = stamp; stale.remoteID = "/Docs/grande.bin"
        var saved: UploadCheckpoint?
        _ = try await api.resumableUpload(local: local, parent: "/Docs", name: "grande.bin", replacing: nil, checkpoint: stale,
                                          save: { saved = $0 }, progress: { _, _ in })
        XCTAssertEqual(created.value, 1, "A collection the server dropped is replaced by a new one")
        XCTAssertEqual(saved?.complete, true)

        await api.abandonUploadSessions(urls: [URL(string: "https://nube.example.com/remote.php/dav/uploads/ana/icloudy-x")!,
                                               URL(string: "https://elsewhere.example.com/remote.php/dav/uploads/ana/y")!,
                                               URL(string: "https://nube.example.com/remote.php/dav/files/ana/Docs")!], sessionIDs: [])
        XCTAssertTrue(deleted.value.contains("/remote.php/dav/uploads/ana/icloudy-x"))
        XCTAssertFalse(deleted.value.contains("/remote.php/dav/files/ana/Docs"), "Nothing but an upload collection is ever deleted")
        XCTAssertEqual(deleted.value.filter { $0.hasSuffix("/y") }.count, 0, "Nor anything on another host")
    }

    func testPlainWebDAVAndSmallFilesKeepTheSinglePut() async throws {
        let methods = Box<[String]>([])
        StubProtocol.handler = { request in methods.value.append(request.httpMethod ?? ""); return (201, [:], Data()) }
        let (plain, _) = client(nextcloud: false)
        _ = try await plain.resumableUpload(local: try source("0123456789"), parent: "/", name: "a.bin", replacing: nil, checkpoint: nil,
                                            save: { _ in }, progress: { _, _ in })
        let (nextcloud, provider) = client()
        provider.chunkedThreshold = 1_000
        _ = try await nextcloud.resumableUpload(local: try source("0123456789"), parent: "/", name: "b.bin", replacing: nil, checkpoint: nil,
                                                save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(methods.value, ["PUT", "PUT"])
        XCTAssertEqual(WebDAVProvider.chunkSize(for: 5 * 1024 * 1024 * 1024 * 1024 / 10), 53 * 1024 * 1024, "Never more than 10,000 chunks")
        XCTAssertEqual(WebDAVProvider.chunkSize(for: 100), 10 * 1024 * 1024)
    }
}
