import XCTest
import CryptoKit
@testable import iCloudy

/// Box over the HTTP stub: markers, search, chunked uploads and their digests.
@MainActor
final class BoxProviderTests: XCTestCase {
    private func client(_ cloud: Cloud, server: String? = nil) -> CloudAPI {
        makeStubbedClient(cloud, server: server ?? (cloud == .webdav ? "https://dav.example.com/remote.php/dav/files/ana" : nil))
    }
    private func temporaryFile(_ payload: Data) throws -> URL {
        let url = try temporaryRoot().appendingPathComponent("payload")
        try payload.write(to: url)
        return url
    }

    func testBoxPaginatesByMarkerAndBuildsTrailFromPathCollection() async throws {
        // Box refuses an offset past 10 000, so a folder with more items than that was cut short at the ten
        // thousandth without a word. A marker has no such ceiling.
        var urls: [URL] = []
        StubProtocol.handler = { request in
            urls.append(request.url!)
            if request.url!.path.hasSuffix("/items") {
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(query.first { $0.name == "usemarker" }?.value, "true")
                XCTAssertNil(query.first { $0.name == "offset" }, "El desplazamiento numérico ya no se usa")
                guard let marker = query.first(where: { $0.name == "marker" })?.value else {
                    return (200, [:], Data(#"{"entries":[{"type":"folder","id":"11","name":"Fotos"}],"next_marker":"m1"}"#.utf8))
                }
                XCTAssertEqual(marker, "m1")
                return (200, [:], Data(#"{"entries":[{"type":"file","id":"12","name":"a.pdf","size":9}]}"#.utf8))
            }
            return (200, [:], Data(#"{"id":"11","name":"Fotos","path_collection":{"entries":[{"type":"folder","id":"0","name":"All Files"},{"type":"folder","id":"5","name":"Trabajo"}]}}"#.utf8))
        }
        let api = client(.box)
        let files = try await api.list(parent: "root")
        XCTAssertEqual(urls[0].path, "/2.0/folders/0/items", "iCloudy's root maps to Box's folder 0")
        XCTAssertEqual(files.map(\.id), ["11", "12"], "Las dos páginas llegan")
        let trail = try await api.folderTrail(id: "11")
        XCTAssertEqual(trail.map(\.name), ["Trabajo", "Fotos"], "The root entry is dropped and the folder itself closes the trail")
    }

    func testBoxSearchStopsWhereBoxStopsAnswering() async throws {
        // Box's search has no marker, and asking past its cap returns an error instead of a page. The results end
        // there and say nothing more, rather than promising a "load more" that cannot work.
        StubProtocol.handler = { request in
            let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!)!
            let entries = (0..<100).map { #"{"type":"file","id":"\#(offset + $0)","name":"a.txt"}"# }.joined(separator: ",")
            return (200, [:], Data(#"{"total_count":50000,"entries":[\#(entries)]}"#.utf8))
        }
        let api = client(.box)
        let early = try await api.searchPage(term: "a", cursor: "0")
        XCTAssertEqual(early.next, "100", "Al principio sí hay más")
        let atTheCap = try await api.searchPage(term: "a", cursor: String(BoxProvider.boxSearchCap - 100))
        XCTAssertNil(atTheCap.next, "Y en el tope se para, aunque el total diga que hay más")
        XCTAssertEqual(atTheCap.hits.count, 100, "Sin perder la última página")
    }

    func testBoxWaitsWhileItIsStillAssemblingTheUpload() async throws {
        // Box answers 202 while it puts the parts together. Taking that for a finished upload returned a transfer
        // with no file behind it, and the id came back empty.
        let size = Int(BoxProvider.boxSessionThreshold) + 512
        let large = try temporaryFile(Data(repeating: 9, count: size))
        defer { try? FileManager.default.removeItem(at: large) }
        let sha1 = UploadHasher.hex(Insecure.SHA1.hash(data: Data(repeating: 9, count: size)))
        var commits = 0
        StubProtocol.handler = { request in
            let path = request.url!.path
            if path == "/api/2.0/files/upload_sessions" { return (201, [:], Data(#"{"id":"s1","part_size":\#(8 * 1024 * 1024)}"#.utf8)) }
            if path.hasSuffix("/commit") {
                commits += 1
                if commits < 3 { return (202, ["Retry-After": "1"], Data()) }
                return (201, [:], Data(#"{"entries":[{"id":"77","sha1":"\#(sha1)"}]}"#.utf8))
            }
            return (200, [:], Data(#"{"part":{"part_id":"p","offset":0,"size":1}}"#.utf8))
        }
        let stamp = try large.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let receipt = try await client(.box).resumableUpload(local: large, parent: "5", name: "big.bin", replacing: nil,
                                                             checkpoint: UploadCheckpoint(total: Int64(size), modified: stamp), save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(commits, 3, "Se vuelve a preguntar hasta que Box confirma")
        XCTAssertEqual(receipt.remoteID, "77")
        XCTAssertEqual(receipt.verification, .verified)
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
        XCTAssertGreaterThan(BoxProvider.boxSessionThreshold, 0)
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
        let size = Int(BoxProvider.boxSessionThreshold) + 1024
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

    func testBoxDoesNotFollowAMarkerThatNeverChanges() async throws {
        // A marker that comes back unchanged is a server, or a cache in front of it, repeating itself; following it
        // grew the listing until the app ran out of memory.
        var requests = 0
        StubProtocol.handler = { _ in
            requests += 1
            return (200, [:], Data(#"{"entries":[{"type":"file","id":"1","name":"a.txt"}],"next_marker":"siempre-igual"}"#.utf8))
        }
        let files = try await client(.box).list(parent: "root")
        XCTAssertEqual(requests, 2, "Se pide la siguiente página una vez y se para al ver el mismo marcador")
        XCTAssertEqual(files.count, 2)
    }
}
