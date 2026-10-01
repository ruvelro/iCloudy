import XCTest
import CryptoKit
@testable import iCloudy

/// The S3 provider against a stubbed HTTP layer: addressing, listings, multipart uploads with resume and abort, the
/// integrity checks on both directions, the error messages and the retries. The signing itself is in S3SignerTests;
/// here it is enough that every request carries a SigV4 header for the stored key.
@MainActor
final class S3ProviderTests: XCTestCase {
    override func tearDown() { StubProtocol.handler = nil; super.tearDown() }

    private func client(bucket: String = "fotos", service: S3Service = .custom, endpoint: String = "https://minio.ejemplo.com",
                        region: String = "us-east-1", addressing: S3Addressing = .automatic) -> (CloudAPI, S3Provider) {
        let account = S3Authentication.account(service, endpoint: URLComponents(string: endpoint)!, region: region, bucket: bucket,
                                               addressing: addressing, accessKey: "AKIDPRUEBA")
        let store = MemoryCredentials()
        store.stored[account.id] = Credential(accessToken: "AKIDPRUEBA", refreshToken: "", expires: .distantFuture, secret: "secreto")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let api = CloudAPI(account: account, session: URLSession(configuration: configuration), credentials: store)
        let provider = api.provider as! S3Provider
        provider.pause = { _ in }
        return (api, provider)
    }
    /// The decoded path with its trailing slash, which `URL.path` drops and S3 keys keep.
    nonisolated private func path(_ request: URLRequest) -> String {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.path ?? ""
    }
    nonisolated private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }
    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("s3-" + UUID().uuidString)
        try data.write(to: url)
        return url
    }
    private func checkpoint(for file: URL, size: Int) throws -> UploadCheckpoint {
        UploadCheckpoint(total: Int64(size), modified: try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
    }
    nonisolated private func md5(_ data: Data) -> String { S3Signer.hex(Insecure.MD5.hash(data: data)) }
    nonisolated private func xmlError(_ code: String, _ message: String = "", extra: String = "") -> Data {
        Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message>\(extra)</Error>".utf8)
    }

    // MARK: - Addressing

    func testPathStyleAndVirtualHostedURLs() throws {
        func location(_ service: S3Service, _ endpoint: String, bucket: String?, _ addressing: S3Addressing = .automatic) -> S3Location {
            S3Location(service: service, endpoint: URLComponents(string: endpoint)!, region: "us-east-1", bucket: bucket, addressing: addressing)
        }
        // A self-hosted server is one host: the bucket goes in the path.
        let minio = location(.custom, "http://nas.local:9000", bucket: "fotos")
        XCTAssertEqual(try minio.url(bucket: "fotos", key: "viaje 2024/ñu+1.jpg").absoluteString,
                       "http://nas.local:9000/fotos/viaje%202024/%C3%B1u%2B1.jpg")
        // AWS puts a DNS-friendly bucket in the host.
        let aws = location(.aws, "https://s3.eu-west-1.amazonaws.com", bucket: "fotos")
        XCTAssertEqual(try aws.url(bucket: "fotos", key: "a/b.txt").absoluteString, "https://fotos.s3.eu-west-1.amazonaws.com/a/b.txt")
        // …but not one with dots over TLS, which the wildcard certificate would not cover.
        XCTAssertEqual(try aws.url(bucket: "mis.fotos", key: "a").absoluteString, "https://s3.eu-west-1.amazonaws.com/mis.fotos/a")
        XCTAssertEqual(try location(.aws, "https://s3.eu-west-1.amazonaws.com", bucket: nil, .path).url(bucket: "fotos", key: "a").absoluteString,
                       "https://s3.eu-west-1.amazonaws.com/fotos/a")
        XCTAssertEqual(try location(.custom, "https://minio.ejemplo.com", bucket: nil, .virtual).url(bucket: "fotos", key: "").absoluteString,
                       "https://fotos.minio.ejemplo.com/")
        // A base path behind a reverse proxy stays in front of the bucket, and the service itself is its root.
        let proxied = location(.custom, "https://ejemplo.com/s3", bucket: nil)
        XCTAssertEqual(try proxied.url(bucket: "b", key: "k", query: [("uploads", nil)]).absoluteString, "https://ejemplo.com/s3/b/k?uploads")
        XCTAssertEqual(try proxied.url(bucket: nil).absoluteString, "https://ejemplo.com/s3/")
        // AWS moves a bucket of another region to that region's host.
        XCTAssertEqual(aws.moved(to: "us-east-2").endpoint.host, "s3.us-east-2.amazonaws.com")
        XCTAssertEqual(minio.moved(to: "us-east-2"), minio, "Only AWS has one host per region")
    }

    func testServiceEndpoints() {
        XCTAssertEqual(S3Service.aws.endpoint(region: "eu-south-2"), "https://s3.eu-south-2.amazonaws.com")
        XCTAssertEqual(S3Service.backblaze.endpoint(region: "us-west-004"), "https://s3.us-west-004.backblazeb2.com")
        XCTAssertEqual(S3Service.wasabi.endpoint(region: "eu-central-1"), "https://s3.eu-central-1.wasabisys.com")
        XCTAssertEqual(S3Service.cloudflare.endpoint(region: "auto", accountID: "abc123"), "https://abc123.r2.cloudflarestorage.com")
        XCTAssertNil(S3Service.cloudflare.endpoint(region: "auto"), "R2 needs the account id")
        XCTAssertEqual(S3Service.digitalocean.endpoint(region: "ams3"), "https://ams3.digitaloceanspaces.com")
        XCTAssertNil(S3Service.custom.endpoint(region: "us-east-1"))
    }

    func testSignInNormalisesTheEndpointAndRefusesPlainHTTPOutsideTheLAN() throws {
        var form = S3SignIn(service: .custom, endpoint: "minio.ejemplo.com:443/")
        XCTAssertEqual(try S3Authentication.endpoint(for: form, region: "us-east-1").url?.absoluteString, "https://minio.ejemplo.com")
        form.endpoint = "http://192.168.1.10:9000"
        XCTAssertEqual(try S3Authentication.endpoint(for: form, region: "us-east-1").url?.absoluteString, "http://192.168.1.10:9000")
        form.endpoint = "http://s3.ejemplo.com"
        XCTAssertThrowsError(try S3Authentication.endpoint(for: form, region: "us-east-1"))
        form = S3SignIn(service: .cloudflare, accountID: "")
        XCTAssertThrowsError(try S3Authentication.endpoint(for: form, region: "auto"))
    }

    // MARK: - Listing

    func testListingReadsPrefixesMarkersAndFollowsContinuationTokens() async throws {
        var pages: [[String: String]] = []
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "minio.ejemplo.com")
            XCTAssertEqual(self.path(request), "/fotos/")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("AWS4-HMAC-SHA256 Credential=AKIDPRUEBA/") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.emptyPayloadHash)
            let q = self.query(request)
            pages.append(q)
            if q["continuation-token"] == nil {
                return (200, [:], Data("""
                <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Name>fotos</Name><Prefix>viaje/</Prefix>
                <IsTruncated>true</IsTruncated><NextContinuationToken>pagina+2</NextContinuationToken>
                <Contents><Key>viaje/</Key><Size>0</Size><ETag>"d41d8cd98f00b204e9800998ecf8427e"</ETag></Contents>
                <Contents><Key>viaje/playa.jpg</Key><LastModified>2024-07-01T10:00:00.000Z</LastModified><Size>2048</Size>
                <ETag>&quot;9E107D9D372BB6826BD81D3542A419D6&quot;</ETag></Contents>
                <CommonPrefixes><Prefix>viaje/dia 1/</Prefix></CommonPrefixes>
                </ListBucketResult>
                """.utf8))
            }
            return (200, [:], Data("""
            <ListBucketResult><IsTruncated>false</IsTruncated>
            <Contents><Key>viaje/video.mov</Key><Size>99</Size><ETag>"1b2cf535f27731c974343645a3985328-3"</ETag></Contents>
            <CommonPrefixes><Prefix>viaje/vacía/</Prefix></CommonPrefixes>
            </ListBucketResult>
            """.utf8))
        }
        let (api, _) = client()
        var streamed: [[String]] = []
        let files = try await api.list(parent: "fotos/viaje/") { streamed.append($0.map(\.name)) }
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages[0]["list-type"], "2"); XCTAssertEqual(pages[0]["delimiter"], "/"); XCTAssertEqual(pages[0]["prefix"], "viaje/")
        XCTAssertEqual(pages[1]["continuation-token"], "pagina+2", "The token goes back exactly as it came")
        XCTAssertEqual(streamed.count, 2, "Each page reaches the view as it arrives")
        XCTAssertEqual(files.map(\.name), ["dia 1", "vacía", "playa.jpg", "video.mov"], "Folders first, and the folder's own marker is not its child")
        XCTAssertEqual(files.map(\.id), ["fotos/viaje/dia 1/", "fotos/viaje/vacía/", "fotos/viaje/playa.jpg", "fotos/viaje/video.mov"])
        XCTAssertTrue(files[0].isFolder && files[1].isFolder)
        XCTAssertEqual(files[2].size, 2048)
        XCTAssertNotNil(files[2].modified)
        XCTAssertEqual(files[2].checksum, ContentHash(algorithm: .md5, value: "9e107d9d372bb6826bd81d3542a419d6"))
        XCTAssertNil(files[3].checksum, "A multipart ETag is not the MD5 of the object")
    }

    func testTheRootOfABucketAccountIsTheBucket() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(self.path(request), "/fotos/")
            XCTAssertEqual(self.query(request)["prefix"], "")
            return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a.txt</Key><Size>1</Size></Contents></ListBucketResult>".utf8))
        }
        let (api, provider) = client()
        let root = try await api.list(parent: "root")
        XCTAssertEqual(root.map(\.id), ["fotos/a.txt"])
        XCTAssertEqual(try provider.s3Trail(id: "root"), [])
        XCTAssertEqual(try provider.s3Trail(id: "fotos/a/b/").map(\.id), ["fotos/a/", "fotos/a/b/"], "The bucket is the root, not a crumb")
    }

    func testWithoutABucketTheRootListsTheBuckets() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "s3.eu-west-1.amazonaws.com")
            XCTAssertEqual(request.url?.path, "/")
            return (200, [:], Data("""
            <ListAllMyBucketsResult><Owner><ID>x</ID></Owner><Buckets>
            <Bucket><Name>zeta</Name><BucketRegion>us-east-2</BucketRegion></Bucket><Bucket><Name>alfa</Name></Bucket>
            </Buckets></ListAllMyBucketsResult>
            """.utf8))
        }
        let (api, provider) = client(bucket: "", service: .aws, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1")
        let buckets = try await api.list(parent: "root")
        XCTAssertEqual(buckets.map(\.id), ["alfa/", "zeta/"])
        XCTAssertTrue(buckets.allSatisfy(\.isFolder))
        XCTAssertEqual(provider.bucketRegions["zeta"], "us-east-2", "The listing says where each bucket lives")
        XCTAssertEqual(try provider.location(for: "zeta").endpoint.host, "s3.us-east-2.amazonaws.com")
        XCTAssertEqual(try provider.s3Trail(id: "zeta/a/").map(\.name), ["zeta", "a"])
        do { _ = try await api.createFolder(name: "nuevo", parent: "root"); XCTFail("No buckets are created from here") }
        catch { XCTAssertTrue(error.localizedDescription.contains("bucket"), error.localizedDescription) }
    }

    func testIdentityChangesKeepTheTrailingSlashOfFolders() throws {
        let (api, _) = client()
        let folder = CloudFile(id: "fotos/a/viaje/", name: "viaje", mime: S3Provider.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
        let renamed = try api.identityChange(file: folder, name: "verano")
        XCTAssertEqual(renamed.newID, "fotos/a/verano/")
        XCTAssertEqual(renamed.id("fotos/a/viaje/dia/1.jpg"), "fotos/a/verano/dia/1.jpg")
        let moved = try api.identityChange(file: folder, name: "viaje", destination: "root")
        XCTAssertEqual(moved.newID, "fotos/viaje/")
        let file = CloudFile(id: "fotos/a/x.txt", name: "x.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        XCTAssertEqual(try api.identityChange(file: file, name: "y.txt").newID, "fotos/a/y.txt")
    }

    func testCreatingAFolderPutsAnEmptyMarker() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(self.path(request), "/fotos/a/nueva/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.emptyPayloadHash)
            XCTAssertTrue(requestData(request).isEmpty)
            return (200, [:], Data())
        }
        let (api, _) = client()
        let id = try await api.createFolder(name: "nueva", parent: "fotos/a/")
        XCTAssertEqual(id, "fotos/a/nueva/")
    }

    // MARK: - Uploads

    func testSmallUploadIsOnePutCheckedWithContentMD5AndTheETag() async throws {
        let payload = Data("hola, S3".utf8)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/fotos/docs/nota.txt")
            let body = requestData(request)
            XCTAssertEqual(body, payload)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), Data(Insecure.MD5.hash(data: payload)).base64EncodedString())
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.sha256Hex(payload), "Small bodies sign their real hash")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "text/plain")
            return (200, ["ETag": "\"\(self.md5(payload))\""], Data())
        }
        let (api, _) = client()
        var saved: [UploadCheckpoint] = []
        let receipt = try await api.resumableUpload(local: file, parent: "fotos/docs/", name: "nota.txt", replacing: nil,
                                                    checkpoint: try checkpoint(for: file, size: payload.count), save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(receipt.remoteID, "fotos/docs/nota.txt")
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertTrue(try XCTUnwrap(saved.last).complete)
    }

    func testSmallUploadFailsWhenTheETagDisagreesAndIsUnverifiedUnderKMS() async throws {
        let payload = Data("contenido".utf8)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let (api, _) = client()
        StubProtocol.handler = { _ in (200, ["ETag": "\"00000000000000000000000000000000\""], Data()) }
        do {
            _ = try await api.resumableUpload(local: file, parent: "root", name: "x.txt", replacing: nil,
                                              checkpoint: try checkpoint(for: file, size: payload.count), save: { _ in }, progress: { _, _ in })
            XCTFail("An ETag that is not the MD5 of what was sent means the stored copy is not that")
        } catch { XCTAssertTrue(error.localizedDescription.contains("suma de verificación"), error.localizedDescription) }
        StubProtocol.handler = { _ in (200, ["ETag": "\"00000000000000000000000000000000\"", "x-amz-server-side-encryption": "aws:kms"], Data()) }
        let receipt = try await api.resumableUpload(local: file, parent: "root", name: "x.txt", replacing: nil,
                                                    checkpoint: try checkpoint(for: file, size: payload.count), save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .unavailable, "Under KMS the ETag is not an MD5, so it proves nothing either way")
    }

    func testPartSizesStayWithinTheLimits() {
        XCTAssertEqual(S3Provider.partSize(for: 20 * 1024 * 1024), 8 * 1024 * 1024)
        let huge: Int64 = 200 * 1024 * 1024 * 1024
        let part = S3Provider.partSize(for: huge)
        XCTAssertLessThanOrEqual((huge + part - 1) / part, 10_000)
        XCTAssertEqual(part % (1024 * 1024), 0)
    }

    func testCompositeETagIsTheMD5OfThePartDigests() {
        // Computed independently: md5(md5("a") ‖ md5("b")) followed by the number of parts.
        XCTAssertEqual(S3Provider.compositeETag(["0cc175b9c0f1b6a831c399e269772661", "92eb5ffee6ae2fec3ad71c777531578f"]),
                       "96e024ba2074fe77e8e965ba43a704be-2")
        XCTAssertNil(S3Provider.compositeETag([]))
        XCTAssertNil(S3Provider.compositeETag(["zz"]))
    }

    /// A stub of the multipart protocol that remembers the parts it accepted, as a server would.
    private final class MultipartServer {
        var parts: [Int: Data] = [:]
        var created = 0, completed = 0, aborted = 0, listed = 0
        var putNumbers: [Int] = []
        var failPart: Int?
        var lostUpload = false
        var finalETag: String?
        func handle(_ request: URLRequest, test: S3ProviderTests) throws -> (Int, [String: String], Data) {
            let q = test.query(request)
            switch (request.httpMethod ?? "GET", q["uploadId"] != nil, q["uploads"] != nil) {
            case ("POST", false, true):
                created += 1
                return (200, [:], Data("<InitiateMultipartUploadResult><Bucket>fotos</Bucket><Key>grande.bin</Key><UploadId>up-\(created)</UploadId></InitiateMultipartUploadResult>".utf8))
            case ("PUT", true, _):
                let number = Int(q["partNumber"]!)!
                putNumbers.append(number)
                if number == failPart { failPart = nil; return (403, [:], test.xmlError("AccessDenied")) }
                let body = requestData(request)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), Data(Insecure.MD5.hash(data: body)).base64EncodedString())
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-content-sha256"), S3Signer.unsignedPayload, "Parts are streamed over TLS")
                parts[number] = body
                return (200, ["ETag": "\"\(test.md5(body))\""], Data())
            case ("GET", true, _):
                listed += 1
                if lostUpload { return (404, [:], test.xmlError("NoSuchUpload")) }
                let entries = parts.keys.sorted().map { "<Part><PartNumber>\($0)</PartNumber><ETag>\"\(test.md5(parts[$0]!))\"</ETag><Size>\(parts[$0]!.count)</Size></Part>" }
                return (200, [:], Data("<ListPartsResult><IsTruncated>false</IsTruncated>\(entries.joined())</ListPartsResult>".utf8))
            case ("POST", true, _):
                completed += 1
                let body = requestBody(request)
                let tags = parts.keys.sorted().map { "<Part><PartNumber>\($0)</PartNumber><ETag>\"\(test.md5(parts[$0]!))\"</ETag></Part>" }
                XCTAssertTrue(body.contains(tags.joined()), body)
                let etag = finalETag ?? S3Provider.compositeETag(parts.keys.sorted().map { test.md5(parts[$0]!) })!
                return (200, [:], Data("<CompleteMultipartUploadResult><Key>grande.bin</Key><ETag>\"\(etag)\"</ETag></CompleteMultipartUploadResult>".utf8))
            case ("DELETE", true, _):
                aborted += 1
                return (204, [:], Data())
            case ("HEAD", false, false):
                return (200, ["ETag": "\"\(S3Provider.compositeETag(parts.keys.sorted().map { test.md5(parts[$0]!) })!)\"", "Content-Length": "0"], Data())
            default:
                XCTFail("Unexpected \(request.httpMethod ?? "") \(request.url!)")
                return (500, [:], Data())
            }
        }
    }

    private func largePayload() -> Data {
        // Two full 8 MiB parts and a short third one.
        // A pattern of prime length, so no two parts carry the same bytes and a part out of place would show.
        let pattern = Data((0..<65_537).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 >> 7) })
        var data = Data(capacity: 17 * 1024 * 1024 + 123)
        while data.count < 17 * 1024 * 1024 + 123 { data.append(pattern.prefix(17 * 1024 * 1024 + 123 - data.count)) }
        return data
    }

    func testMultipartUploadChecksEveryPartAndTheCompositeETag() async throws {
        let payload = largePayload()
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MultipartServer()
        StubProtocol.handler = { try server.handle($0, test: self) }
        let (api, _) = client()
        var saved: [UploadCheckpoint] = []
        let receipt = try await api.resumableUpload(local: file, parent: "root", name: "grande.bin", replacing: nil,
                                                    checkpoint: try checkpoint(for: file, size: payload.count), save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertEqual(receipt.remoteID, "fotos/grande.bin")
        XCTAssertEqual(server.putNumbers, [1, 2, 3])
        XCTAssertEqual(server.parts.keys.sorted().map { server.parts[$0]! }.reduce(Data(), +), payload)
        XCTAssertEqual(saved.first { $0.sessionID != nil }?.sessionID, "up-1\nfotos/grande.bin", "The upload is checkpointed before any part")
        XCTAssertEqual(saved.first { $0.parts.count == 1 }?.parts.first.flatMap(S3PartRecord.init)?.verified, true)
        let last = try XCTUnwrap(saved.last)
        XCTAssertTrue(last.complete)
        XCTAssertNil(last.sessionID, "A finished upload leaves nothing to abort")
    }

    func testMultipartUploadFailsWhenTheServerAssemblesSomethingElse() async throws {
        let payload = largePayload()
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MultipartServer()
        server.finalETag = "ffffffffffffffffffffffffffffffff-3"
        StubProtocol.handler = { try server.handle($0, test: self) }
        let (api, _) = client()
        do {
            _ = try await api.resumableUpload(local: file, parent: "root", name: "grande.bin", replacing: nil,
                                              checkpoint: try checkpoint(for: file, size: payload.count), save: { _ in }, progress: { _, _ in })
            XCTFail("A composite ETag that does not match the parts sent must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("suma de verificación"), error.localizedDescription) }
    }

    func testMultipartUploadResumesFromTheListedPartsAfterRehashingThem() async throws {
        let payload = largePayload()
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MultipartServer()
        server.failPart = 3
        StubProtocol.handler = { try server.handle($0, test: self) }
        let (api, _) = client()
        var saved: [UploadCheckpoint] = []
        do {
            _ = try await api.resumableUpload(local: file, parent: "root", name: "grande.bin", replacing: nil,
                                              checkpoint: try checkpoint(for: file, size: payload.count), save: { saved.append($0) }, progress: { _, _ in })
            XCTFail("The third part was refused")
        } catch {}
        var resumed = try XCTUnwrap(saved.last)
        XCTAssertEqual(resumed.parts.count, 2)
        XCTAssertEqual(resumed.offset, 16 * 1024 * 1024)
        // The checkpoint's own memory of part 2 is wrong: only what the server lists, and the file confirms, counts.
        resumed.parts[1] = S3PartRecord(etag: "nada", md5: "nada").raw
        server.putNumbers = []
        // The server lost part 2, as if it had never arrived.
        server.parts[2] = Data("otra cosa".utf8)
        let receipt = try await api.resumableUpload(local: file, parent: "root", name: "grande.bin", replacing: nil,
                                                    checkpoint: resumed, save: { saved.append($0) }, progress: { _, _ in })
        XCTAssertEqual(server.listed, 1, "Resuming asks the server which parts it has")
        XCTAssertEqual(server.created, 1, "…and keeps the same upload")
        XCTAssertEqual(server.putNumbers, [2, 3], "Part 1 matched the file; part 2 did not, so it and what follows go again")
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertEqual(server.parts.keys.sorted().map { server.parts[$0]! }.reduce(Data(), +), payload)
    }

    func testAnUploadWhoseAnswerWasLostIsRecognisedOnResume() async throws {
        let payload = largePayload()
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let server = MultipartServer()
        StubProtocol.handler = { try server.handle($0, test: self) }
        let (api, _) = client()
        var saved: [UploadCheckpoint] = []
        _ = try await api.resumableUpload(local: file, parent: "root", name: "grande.bin", replacing: nil,
                                          checkpoint: try checkpoint(for: file, size: payload.count), save: { saved.append($0) }, progress: { _, _ in })
        // The last checkpoint before completion: every part sent, the session still open.
        let pending = try XCTUnwrap(saved.last { $0.sessionID != nil && $0.offset == Int64(payload.count) })
        server.lostUpload = true; server.putNumbers = []
        let receipt = try await api.resumableUpload(local: file, parent: "root", name: "grande.bin", replacing: nil,
                                                    checkpoint: pending, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertEqual(server.created, 1, "Nothing is uploaded again")
        XCTAssertEqual(server.putNumbers, [])
    }

    func testCancellingAbortsTheMultipartUpload() async throws {
        var aborted: URLRequest?
        StubProtocol.handler = { request in aborted = request; return (204, [:], Data()) }
        let (api, _) = client()
        await api.abandonUploadSessions(urls: [], boxSessions: [S3UploadSession(uploadID: "up-7", objectID: "fotos/a b/grande.bin").raw, "basura"])
        let request = try XCTUnwrap(aborted)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.url?.path, "/fotos/a b/grande.bin")
        XCTAssertEqual(query(request)["uploadId"], "up-7")
    }

    // MARK: - Downloads

    func testLargeDownloadsComeInRangesPinnedToTheFirstETag() async throws {
        let payload = Data("0123456789".utf8)
        var ranges: [String] = [], matches: [String?] = []
        StubProtocol.handler = { request in
            let range = try XCTUnwrap(request.value(forHTTPHeaderField: "Range"))
            ranges.append(range); matches.append(request.value(forHTTPHeaderField: "If-Match"))
            let bounds = range.dropFirst("bytes=".count).split(separator: "-").map { Int($0)! }
            return (206, ["ETag": "\"\(self.md5(payload))\""], payload.subdata(in: bounds[0]..<(bounds[1] + 1)))
        }
        let (api, provider) = client()
        provider.downloadPiece = 4
        let file = CloudFile(id: "fotos/n.txt", name: "n.txt", mime: "text/plain", size: 10, modified: nil, webURL: nil, isFolder: false,
                             checksum: ContentHash(algorithm: .md5, value: md5(payload)))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let verification = try await api.download(file: file, to: destination)
        XCTAssertEqual(ranges, ["bytes=0-3", "bytes=4-7", "bytes=8-9"])
        XCTAssertEqual(matches, [nil, "\"\(md5(payload))\"", "\"\(md5(payload))\""])
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(verification, .verified, "A plain ETag is the MD5, and the shared check compares it")
    }

    func testAKMSObjectIsCheckedBySizeOnly() async throws {
        let payload = Data("cifrado con KMS".utf8)
        StubProtocol.handler = { request in
            if request.httpMethod == "HEAD" { return (200, ["Content-Length": String(payload.count)], Data()) }
            return (200, ["ETag": "\"0123456789abcdef0123456789abcdef\"", "x-amz-server-side-encryption": "aws:kms"], payload)
        }
        let (api, _) = client()
        let file = CloudFile(id: "fotos/k.txt", name: "k.txt", mime: "text/plain", size: Int64(payload.count), modified: nil, webURL: nil,
                             isFolder: false, checksum: ContentHash(algorithm: .md5, value: "0123456789abcdef0123456789abcdef"))
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        let verification = try await api.download(file: file, to: destination)
        XCTAssertEqual(verification, .unavailable, "The ETag of a KMS object looks like an MD5 and is not one")
    }

    // MARK: - Copy, move, delete, links, search

    func testRenamingAFolderCopiesEveryKeyThenDeletesThemInOneBatch() async throws {
        var copies: [String: String] = [:]
        var deleted = ""
        StubProtocol.handler = { request in
            let q = self.query(request)
            switch request.httpMethod {
            case "GET" where q["prefix"] == "viaje/":
                XCTAssertNil(q["delimiter"], "Everything under the folder, at any depth")
                return (200, [:], Data("""
                <ListBucketResult><IsTruncated>false</IsTruncated>
                <Contents><Key>viaje/</Key><Size>0</Size></Contents>
                <Contents><Key>viaje/a.jpg</Key><Size>5</Size></Contents>
                <Contents><Key>viaje/dia 2/b.jpg</Key><Size>6</Size></Contents>
                </ListBucketResult>
                """.utf8))
            case "GET":
                XCTAssertEqual(q["prefix"], "verano/", "The destination is checked first")
                return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
            case "PUT":
                copies[self.path(request)] = request.value(forHTTPHeaderField: "x-amz-copy-source")
                return (200, [:], Data("<CopyObjectResult><ETag>\"x\"</ETag></CopyObjectResult>".utf8))
            case "POST":
                XCTAssertNotNil(q["delete"])
                let body = requestData(request)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), Data(Insecure.MD5.hash(data: body)).base64EncodedString())
                deleted = String(decoding: body, as: UTF8.self)
                return (200, [:], Data("<DeleteResult></DeleteResult>".utf8))
            default:
                XCTFail("Unexpected \(request.httpMethod ?? "")"); return (500, [:], Data())
            }
        }
        let (api, provider) = client()
        var reports: [String] = []
        provider.relocationProgress = { reports.append("\($0)/\($1)") }
        let folder = CloudFile(id: "fotos/viaje/", name: "viaje", mime: S3Provider.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
        try await api.rename(file: folder, name: "verano")
        XCTAssertEqual(copies, ["/fotos/verano/": "/fotos/viaje/", "/fotos/verano/a.jpg": "/fotos/viaje/a.jpg",
                                "/fotos/verano/dia 2/b.jpg": "/fotos/viaje/dia%202/b.jpg"])
        XCTAssertEqual(reports, ["0/3", "1/3", "2/3", "3/3"])
        XCTAssertTrue(deleted.contains("<Object><Key>viaje/</Key></Object><Object><Key>viaje/a.jpg</Key></Object><Object><Key>viaje/dia 2/b.jpg</Key></Object>"), deleted)
        XCTAssertTrue(deleted.contains("<Quiet>true</Quiet>"))
    }

    func testRenamingOntoAnExistingNameIsRefused() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "HEAD", "Nothing is copied over an existing object")
            return (200, ["Content-Length": "3"], Data())
        }
        let (api, _) = client()
        let file = CloudFile(id: "fotos/a.txt", name: "a.txt", mime: "text/plain", size: 3, modified: nil, webURL: nil, isFolder: false)
        do { try await api.rename(file: file, name: "b.txt"); XCTFail("S3 would overwrite b.txt without a word") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Ya existe"), error.localizedDescription) }
    }

    func testCopiesAbove5GiBAreAssembledWithUploadPartCopy() async throws {
        var ranges: [String] = []
        var completed = false
        StubProtocol.handler = { request in
            let q = self.query(request)
            switch request.httpMethod {
            case "HEAD": return (404, [:], Data())
            case "POST" where q["uploads"] != nil:
                return (200, [:], Data("<InitiateMultipartUploadResult><UploadId>copia</UploadId></InitiateMultipartUploadResult>".utf8))
            case "PUT":
                XCTAssertEqual(q["uploadId"], "copia")
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-amz-copy-source"), "/fotos/enorme.iso")
                ranges.append(request.value(forHTTPHeaderField: "x-amz-copy-source-range") ?? "")
                return (200, [:], Data("<CopyPartResult><ETag>\"p\(ranges.count)\"</ETag></CopyPartResult>".utf8))
            case "POST":
                completed = true
                return (200, [:], Data("<CompleteMultipartUploadResult><ETag>\"x-12\"</ETag></CompleteMultipartUploadResult>".utf8))
            default: XCTFail(); return (500, [:], Data())
            }
        }
        let (api, _) = client()
        let size: Int64 = 6 * 1024 * 1024 * 1024
        let file = CloudFile(id: "fotos/enorme.iso", name: "enorme.iso", mime: "application/octet-stream", size: size, modified: nil, webURL: nil, isFolder: false)
        try await api.copy(file: file, to: "fotos/copias/")
        XCTAssertEqual(ranges.count, 12)
        XCTAssertEqual(ranges.first, "bytes=0-536870911")
        XCTAssertEqual(ranges.last, "bytes=5905580032-6442450943")
        XCTAssertTrue(completed)
    }

    func testDeletingAFolderRemovesEveryKeyUnderIt() async throws {
        var deleted = ""
        StubProtocol.handler = { request in
            if request.httpMethod == "GET" {
                return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated><Contents><Key>a/</Key></Contents><Contents><Key>a/b</Key></Contents></ListBucketResult>".utf8))
            }
            deleted = requestBody(request)
            return (200, [:], Data("<DeleteResult><Error><Key>a/b</Key><Code>AccessDenied</Code><Message>no</Message></Error></DeleteResult>".utf8))
        }
        let (api, _) = client()
        let folder = CloudFile(id: "fotos/a/", name: "a", mime: S3Provider.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
        do { try await api.trash(file: folder); XCTFail("A key the server refused to delete is reported") }
        catch { XCTAssertTrue(error.localizedDescription.contains("denegado"), error.localizedDescription) }
        XCTAssertTrue(deleted.contains("<Key>a/</Key>") && deleted.contains("<Key>a/b</Key>"), deleted)
        let bucket = CloudFile(id: "fotos/", name: "fotos", mime: S3Provider.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)
        do { try await api.trash(file: bucket); XCTFail("A whole bucket is not deleted from here") }
        catch { XCTAssertTrue(error.localizedDescription.contains("bucket"), error.localizedDescription) }
    }

    func testPublicLinksArePresignedAndTemporary() async throws {
        StubProtocol.handler = { _ in XCTFail("Presigning needs no request"); return (500, [:], Data()) }
        let (api, provider) = client()
        let file = CloudFile(id: "fotos/a b.jpg", name: "a b.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        let link = try await api.publicLink(for: file)
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(link.path, "/fotos/a b.jpg")
        XCTAssertEqual(items.first { $0.name == "X-Amz-Expires" }?.value, "86400")
        XCTAssertTrue(items.first { $0.name == "X-Amz-Credential" }?.value?.hasPrefix("AKIDPRUEBA/") == true)
        XCTAssertEqual(items.last?.name, "X-Amz-Signature")
        let week = try provider.temporaryLink(for: file, lifetime: 7 * 86400)
        XCTAssertTrue(week.absoluteString.contains("X-Amz-Expires=604800"))
        XCTAssertFalse(api.account.capabilities.allows(.publicLink, on: [CloudFile(id: "fotos/x/", name: "x", mime: S3Provider.folderMime, size: nil, modified: nil, webURL: nil, isFolder: true)]))
    }

    func testSearchIsByKeyPrefixAndSaysItIsLimited() async throws {
        StubProtocol.handler = { request in
            let q = self.query(request)
            XCTAssertEqual(q["prefix"], "informes/2024")
            XCTAssertNil(q["delimiter"])
            return (200, [:], Data("""
            <ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>t2</NextContinuationToken>
            <Contents><Key>informes/2024/enero.pdf</Key><Size>10</Size></Contents></ListBucketResult>
            """.utf8))
        }
        let (api, _) = client()
        let page = try await api.searchPage(term: "/informes/2024")
        XCTAssertEqual(page.hits.map(\.file.id), ["fotos/informes/2024/enero.pdf"])
        XCTAssertEqual(page.hits.first?.parentID, "fotos/informes/2024/")
        XCTAssertEqual(page.next, "0\nt2")
        XCTAssertTrue(page.incomplete)
    }

    // MARK: - Errors and retries

    func testErrorsReadLikeAdvice() {
        func message(_ code: String, region: String? = nil) -> String {
            S3Failure.message(status: 403, body: S3ErrorBody(code: code, message: "m", region: region, serverTime: nil), bucket: "fotos")
        }
        XCTAssertTrue(message("AccessDenied").contains("denegado"))
        XCTAssertTrue(message("NoSuchBucket").contains("«fotos»"))
        XCTAssertTrue(message("SignatureDoesNotMatch").contains("hora del Mac"), "A bad signature is often a clock")
        XCTAssertTrue(message("RequestTimeTooSkewed").contains("hora"))
        XCTAssertTrue(message("PermanentRedirect", region: "us-east-2").contains("us-east-2"))
        XCTAssertTrue(message("XNuevo").contains("XNuevo: m"))
        XCTAssertTrue(S3Failure.message(status: 404, body: nil, bucket: nil).contains("ya no existe"), "A HEAD has no body")
    }

    func testAnUnknownKeyExpiresTheSessionAndADeniedOneDoesNot() async throws {
        let (api, provider) = client()
        StubProtocol.handler = { _ in (403, [:], self.xmlError("AccessDenied", "Access Denied")) }
        do { _ = try await api.list(parent: "root"); XCTFail() }
        catch let error as ServiceError { XCTAssertEqual(error.status, 403); XCTAssertEqual(error.code, "AccessDenied") }
        XCTAssertFalse(provider.sessionExpired)
        StubProtocol.handler = { _ in (403, [:], self.xmlError("InvalidAccessKeyId")) }
        do { _ = try await api.list(parent: "root"); XCTFail() }
        catch { XCTAssertTrue((error as? CloudError)?.isSessionExpired == true, "\(error)") }
        XCTAssertTrue(provider.sessionExpired, "Only new keys fix this, so the account asks to be reconnected")
    }

    func testSlowDownIsRepeatedAfterAPause() async throws {
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            if calls < 3 { return (503, [:], self.xmlError("SlowDown", "Please reduce your request rate.")) }
            return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        let (api, provider) = client()
        var pauses: [Double] = []
        provider.pause = { pauses.append($0) }
        _ = try await api.list(parent: "root")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(pauses, [1, 2], "The shared policy: one second, then two")
        // A POST that is not repeatable is not repeated, whatever the status.
        calls = 0
        StubProtocol.handler = { _ in calls += 1; return (503, [:], self.xmlError("SlowDown")) }
        do { _ = try await provider.s3(S3Call(method: "POST", bucket: "fotos", key: "k", query: [("uploads", nil)])); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("ritmo"), error.localizedDescription) }
        XCTAssertEqual(calls, 1)
    }

    func testABucketInAnotherAWSRegionIsFollowed() async throws {
        var hosts: [String] = [], scopes: [String] = []
        StubProtocol.handler = { request in
            hosts.append(request.url!.host!)
            scopes.append(String(request.value(forHTTPHeaderField: "Authorization")!.split(separator: "/")[2]))
            if hosts.count == 1 {
                return (301, ["x-amz-bucket-region": "us-east-2"], self.xmlError("PermanentRedirect", "The bucket you are attempting to access must be addressed using the specified endpoint."))
            }
            return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        let (api, provider) = client(service: .aws, endpoint: "https://s3.eu-west-1.amazonaws.com", region: "eu-west-1")
        _ = try await api.list(parent: "root")
        XCTAssertEqual(hosts, ["fotos.s3.eu-west-1.amazonaws.com", "fotos.s3.us-east-2.amazonaws.com"])
        XCTAssertEqual(scopes, ["eu-west-1", "us-east-2"], "Signed for the region it is sent to")
        XCTAssertEqual(provider.bucketRegions["fotos"], "us-east-2")
    }

    func testAClockThatDriftedAdoptsTheServerTime() async throws {
        var stamps: [String] = []
        StubProtocol.handler = { request in
            stamps.append(request.value(forHTTPHeaderField: "x-amz-date")!)
            if stamps.count == 1 {
                return (403, [:], self.xmlError("RequestTimeTooSkewed", "The difference is too large.", extra: "<ServerTime>2030-01-02T03:04:05Z</ServerTime>"))
            }
            return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        let (api, provider) = client()
        _ = try await api.list(parent: "root")
        XCTAssertEqual(stamps.count, 2)
        XCTAssertTrue(stamps[1].hasPrefix("20300102T0304"), stamps[1])
        XCTAssertGreaterThan(provider.clockOffset, 0)
    }

    func testSignInFindsTheRegionOfTheBucket() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        var calls = 0
        StubProtocol.handler = { request in
            calls += 1
            if calls == 1 { return (400, ["x-amz-bucket-region": "ap-south-1"], self.xmlError("AuthorizationHeaderMalformed", "", extra: "<Region>ap-south-1</Region>")) }
            XCTAssertEqual(request.url?.host, "datos.s3.ap-south-1.amazonaws.com")
            return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8))
        }
        let form = S3SignIn(service: .aws, region: "eu-west-1", accessKey: " AKID ", secretKey: "secreto", bucket: "datos")
        let (account, credential) = try await S3Authentication(session: URLSession(configuration: configuration)).signIn(form)
        XCTAssertEqual(account.cloud, .s3)
        XCTAssertEqual(account.id, "s3:s3.ap-south-1.amazonaws.com/datos#AKID")
        XCTAssertEqual(account.serverURL, "https://s3.ap-south-1.amazonaws.com")
        XCTAssertEqual(account.options["region"], "ap-south-1")
        XCTAssertEqual(account.options["bucket"], "datos")
        XCTAssertEqual(account.name, "datos")
        XCTAssertEqual(credential.accessToken, "AKID")
        XCTAssertEqual(credential.secret, "secreto", "The secret goes to the Keychain with the credential")
    }

    func testSignInWithoutBucketExplainsAKeyThatCannotListThem() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        StubProtocol.handler = { _ in (403, [:], self.xmlError("AccessDenied")) }
        let form = S3SignIn(service: .backblaze, region: "eu-central-003", accessKey: "k", secretKey: "s")
        do { _ = try await S3Authentication(session: URLSession(configuration: configuration)).signIn(form); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("nombre del bucket"), error.localizedDescription) }
    }

    // MARK: - Capabilities

    func testWhatS3OffersAndWhatItSaysIsMissing() async throws {
        let capabilities = Cloud.s3.capabilities
        XCTAssertFalse(capabilities.reversibleTrash, "No bin: deleting is final and the confirmation says so")
        XCTAssertFalse(capabilities.quota)
        XCTAssertTrue(capabilities.search)
        XCTAssertTrue(capabilities.checksum)
        XCTAssertFalse(capabilities.linksFolders)
        XCTAssertFalse(capabilities.trashListing || capabilities.permanentDelete || capabilities.memberSharing)
        XCTAssertTrue(Cloud.s3.usesPasswordLogin)
        XCTAssertFalse(Cloud.s3.isSelfHosted, "AWS is not the user's server, even if MinIO is")
        XCTAssertEqual(Cloud.s3.title, "S3")
        let (api, _) = client()
        XCTAssertEqual(AppModel.collections(for: api.account), [.files])
        do { _ = try await api.storageQuota(); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.contains("espacio disponible"), error.localizedDescription) }
    }
}
