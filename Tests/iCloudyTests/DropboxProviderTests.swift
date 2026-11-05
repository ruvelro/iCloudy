import XCTest
import CryptoKit
@testable import iCloudy

/// Dropbox over the HTTP stub: listing, writes, upload sessions and content hashes.
@MainActor
final class DropboxProviderTests: XCTestCase {
    private func client(_ cloud: Cloud, server: String? = nil) -> CloudAPI {
        makeStubbedClient(cloud, server: server ?? (cloud == .webdav ? "https://dav.example.com/remote.php/dav/files/ana" : nil))
    }
    private func temporaryFile(_ payload: Data) throws -> URL {
        let url = try temporaryRoot().appendingPathComponent("payload")
        try payload.write(to: url)
        return url
    }

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
        XCTAssertEqual((api.provider as! DropboxProvider).dropboxTrail(id: "/uno/dos/tres").map(\.name), ["uno", "dos", "tres"], "Breadcrumbs need no request")
        XCTAssertEqual((api.provider as! DropboxProvider).dropboxTrail(id: "/uno/dos/tres").map(\.id), ["/uno", "/uno/dos", "/uno/dos/tres"])
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
        XCTAssertEqual(saved.first(where: { $0.sessionID != nil })?.sessionID, "s1", "The session is checkpointed before any byte is sent")
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

    func testDropboxFollowsTheOffsetItSaysItIsWaitingFor() async throws {
        // Dropbox cannot be asked how far a session got, and the local checkpoint is written in batches, so after a
        // crash it can be behind. Its 409 says which offset it expects; ignoring it left the transfer failed for good.
        let payload = Data(repeating: 6, count: 3 * 1024 * 1024)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        var offsets: [Int64] = []
        var refused = false
        StubProtocol.handler = { request in
            let argument = request.value(forHTTPHeaderField: "Dropbox-API-Arg") ?? ""
            if request.url!.path.hasSuffix("start") { return (200, [:], Data(#"{"session_id":"s1"}"#.utf8)) }
            if request.url!.path.hasSuffix("append_v2") {
                let sent = (try? JSONSerialization.jsonObject(with: Data(argument.utf8))) as? [String: Any]
                let offset = ((sent?["cursor"] as? [String: Any])?["offset"] as? NSNumber)?.int64Value ?? -1
                offsets.append(offset)
                if !refused {
                    refused = true
                    return (409, [:], Data(#"{"error_summary":"incorrect_offset/","error":{".tag":"incorrect_offset","correct_offset":1048576}}"#.utf8))
                }
                return (200, [:], Data())
            }
            return (200, [:], Data(#"{"path_lower":"/x"}"#.utf8))
        }
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        var saved: [UploadCheckpoint] = []
        let receipt = try await client(.dropbox).resumableUpload(local: file, parent: "/", name: "x", replacing: nil,
                                                                 checkpoint: UploadCheckpoint(total: Int64(payload.count), modified: stamp),
                                                                 save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(offsets, [0, 1_048_576], "Se reanuda donde Dropbox dice, no donde creíamos")
        XCTAssertEqual(saved.last?.offset, Int64(payload.count))
        XCTAssertTrue(saved.last?.complete == true)
        XCTAssertEqual(receipt.verification, .unavailable, "Saltarse bloques impide comprobar la suma, y se dice")
    }

    func testDropboxIsNotFollowedForEverWhenItKeepsRefusingTheSameOffset() async throws {
        // Following the offset it asks for is the recovery; following the same one over and over is a client
        // hammering the content host without moving, which is worse than the failure it replaced.
        let payload = Data(repeating: 6, count: 3 * 1024 * 1024)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        var appends = 0
        StubProtocol.handler = { request in
            if request.url!.path.hasSuffix("start") { return (200, [:], Data(#"{"session_id":"s1"}"#.utf8)) }
            if request.url!.path.hasSuffix("append_v2") {
                appends += 1
                return (409, [:], Data(#"{"error_summary":"incorrect_offset/","error":{".tag":"incorrect_offset","correct_offset":1048576}}"#.utf8))
            }
            return (200, [:], Data(#"{"path_lower":"/x"}"#.utf8))
        }
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        do {
            _ = try await client(.dropbox).resumableUpload(local: file, parent: "/", name: "x", replacing: nil,
                                                          checkpoint: UploadCheckpoint(total: Int64(payload.count), modified: stamp),
                                                          save: { _ in }, progress: { _, _ in })
            XCTFail("Debe rendirse en algún momento")
        } catch { XCTAssertTrue(error.localizedDescription.contains("sigue rechazando"), error.localizedDescription) }
        XCTAssertLessThanOrEqual(appends, 3, "Y sin machacar el servidor: \(appends) intentos")
    }
}
