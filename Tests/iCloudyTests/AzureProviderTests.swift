import XCTest
import CryptoKit
@testable import iCloudy

/// Azure Blob Storage over the HTTP stub: the Shared Key signature against Microsoft's documented example, SAS,
/// listings with markers, block uploads that resume, ranged downloads, copies and links.
@MainActor
final class AzureProviderTests: XCTestCase {
    /// Azurite's well-known development key, published by Microsoft so that tests can sign with it.
    private let key = "Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw=="

    private func client(auth: AzureAuth = .sharedKey, container: String? = "fotos", secret: String? = nil) -> (CloudAPI, AzureProvider) {
        var options = [AzureLocation.accountOption: "cuenta", AzureLocation.authOption: auth.rawValue]
        if let container { options[AzureLocation.containerOption] = container }
        let account = stubbedAccount(.azure, id: "azure:test", server: "https://cuenta.blob.core.windows.net", options: options)
        let store = MemoryCredentials()
        store.stored[account.id] = Credential(accessToken: "cuenta", refreshToken: "", expires: .distantFuture,
                                              secret: secret ?? (auth == .sharedKey ? key : "sv=2021-08-06&ss=b&sp=rl&sig=abc%2B%3D"))
        let api = makeStubbedClient(account, credentials: store)
        let provider = api.provider as! AzureProvider
        provider.pause = { _ in }
        return (api, provider)
    }
    private func query(_ request: URLRequest) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testTheSharedKeyStringToSignMatchesMicrosoftsExample() throws {
        // "Authorize with Shared Key", Get Container Metadata with a timeout, signed with version 2009-09-19.
        let url = URL(string: "https://myaccount.blob.core.windows.net/mycontainer?restype=container&comp=metadata&timeout=20")!
        let headers = ["x-ms-date": "Sun, 11 Oct 2009 21:49:13 GMT", "x-ms-version": "2009-09-19"]
        let text = AzureSigner.stringToSign(method: "GET", url: url, headers: headers, account: "myaccount")
        XCTAssertEqual(text, "GET\n\n\n\n\n\n\n\n\n\n\n\nx-ms-date:Sun, 11 Oct 2009 21:49:13 GMT\nx-ms-version:2009-09-19\n/myaccount/mycontainer\ncomp:metadata\nrestype:container\ntimeout:20")
        // HMAC-SHA256 of that string under the published development key, computed independently.
        XCTAssertEqual(AzureSigner.signature(text, key: Data(base64Encoded: key)!), "m649E40iEJ3QQyCg9/WI2Fa9zS+RB/2rEBcLJb0CKs0=")
        XCTAssertTrue(AzureSigner.authorization(method: "GET", url: url, headers: headers, account: "myaccount", key: Data(base64Encoded: key)!)
            .hasPrefix("SharedKey myaccount:"))
    }

    func testCanonicalisationDetails() {
        // Azurite puts the account in the path, so the resource names it twice, as the documentation's example does.
        let azurite = URL(string: "http://127.0.0.1:10000/devstoreaccount1/fotos/a%20b.jpg")!
        XCTAssertEqual(AzureSigner.canonicalResource(url: azurite, account: "devstoreaccount1"), "/devstoreaccount1/devstoreaccount1/fotos/a%20b.jpg")
        let zero = AzureSigner.stringToSign(method: "PUT", url: azurite, headers: ["Content-Length": "0", "x-ms-version": "v"], account: "a")
        XCTAssertTrue(zero.hasPrefix("PUT\n\n\n\n"), "An empty body signs an empty Content-Length")
        let listing = URL(string: "https://a.blob.core.windows.net/?comp=list&marker=m%2B1")!
        XCTAssertEqual(AzureSigner.canonicalResource(url: listing, account: "a"), "/a/\ncomp:list\nmarker:m+1", "Values are signed decoded")
    }

    func testABlobSASIsSignedWithTheVersion2020StringToSign() throws {
        let formatter = ISO8601DateFormatter()
        let items = AzureSigner.blobSAS(account: "myaccount", container: "fotos", blob: "playa 1.jpg", key: Data(base64Encoded: key)!,
                                        start: formatter.date(from: "2026-11-06T10:00:00Z")!, expiry: formatter.date(from: "2026-11-07T10:00:00Z")!)
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["sig"], "m0DDz4LCeDTfMyr1AYQ+6cD2n8zkL7i4B5Ccqm4BqVM=")
        XCTAssertEqual(fields["sr"], "b"); XCTAssertEqual(fields["sp"], "r"); XCTAssertEqual(fields["spr"], "https")
        XCTAssertEqual(fields["sv"], AzureSigner.version)
    }

    func testContainersAreListedPageByPageWithMarkers() async throws {
        var markers: [String?] = []
        StubProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("SharedKey cuenta:") == true)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-version"), AzureSigner.version)
            let query = self.query(request)
            XCTAssertEqual(query["comp"], "list")
            markers.append(query["marker"])
            let page = query["marker"] == nil
                ? "<EnumerationResults><Containers><Container><Name>fotos</Name></Container></Containers><NextMarker>m2</NextMarker></EnumerationResults>"
                : "<EnumerationResults><Containers><Container><Name>docs</Name></Container></Containers><NextMarker/></EnumerationResults>"
            return (200, [:], Data(("\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\"?>" + page).utf8))
        }
        let (api, _) = client(container: nil)
        let roots = try await api.list(parent: "root")
        XCTAssertEqual(roots.map(\.name), ["docs", "fotos"])
        XCTAssertEqual(roots.map(\.id), ["docs/", "fotos/"])
        XCTAssertEqual(markers, [nil, "m2"])
    }

    func testFoldersComeFromPrefixesAndTheChecksumFromContentMD5() async throws {
        let md5 = Data(Insecure.MD5.hash(data: Data("hola".utf8)))
        StubProtocol.handler = { request in
            let query = self.query(request)
            XCTAssertEqual(request.url?.path, "/fotos")
            XCTAssertEqual(query["restype"], "container"); XCTAssertEqual(query["delimiter"], "/"); XCTAssertEqual(query["prefix"], "viaje/")
            return (200, [:], Data("""
            <EnumerationResults><Blobs>
            <Blob><Name>viaje/</Name><Properties><Content-Length>0</Content-Length></Properties></Blob>
            <Blob><Name>viaje/nota.txt</Name><Properties><Last-Modified>Mon, 12 Jan 2026 10:00:00 GMT</Last-Modified><Content-Length>4</Content-Length><Content-MD5>\(md5.base64EncodedString())</Content-MD5></Properties></Blob>
            <BlobPrefix><Name>viaje/dia1/</Name></BlobPrefix>
            </Blobs><NextMarker/></EnumerationResults>
            """.utf8))
        }
        let (api, _) = client()
        let files = try await api.list(parent: "fotos/viaje/")
        XCTAssertEqual(files.map(\.name), ["dia1", "nota.txt"], "The folder's own marker is not a child of it")
        XCTAssertTrue(files[0].isFolder)
        XCTAssertEqual(files[1].checksum, ContentHash(algorithm: .md5, value: md5.map { String(format: "%02x", $0) }.joined()))
        XCTAssertEqual(files[1].modified, Date(timeIntervalSince1970: 1_768_212_000))
    }

    func testASASAccountSendsItsTokenAndNoSignature() async throws {
        var seen: URLRequest?
        StubProtocol.handler = { request in seen = request; return (200, [:], Data("<EnumerationResults><Blobs/></EnumerationResults>".utf8)) }
        let (api, provider) = client(auth: .sas)
        _ = try await api.list(parent: "root")
        XCTAssertNil(seen?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(seen?.url?.query?.contains("sig=abc%2B%3D") == true, "The token rides on the request as it was pasted")
        let file = CloudFile(id: "fotos/a.jpg", name: "a.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        XCTAssertThrowsError(try provider.temporaryLink(for: file, lifetime: 3600), "A SAS token cannot sign a new link")
    }

    func testABlockUploadResumesWithTheNextBlockAndCommitsInOrder() async throws {
        let payload = Data("0123456789".utf8)
        let failSecond = Box(true)
        let blocks = Box<[(id: String, body: String)]>([])
        var commit: URLRequest?
        StubProtocol.handler = { request in
            let query = self.query(request)
            XCTAssertEqual(request.url?.path, "/fotos/grande.bin")
            if query["comp"] == "block" {
                let body = requestData(request)
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), Data(Insecure.MD5.hash(data: body)).base64EncodedString())
                if blocks.value.count == 1, failSecond.value { failSecond.value = false; return (400, [:], Data("<Error><Code>InvalidInput</Code></Error>".utf8)) }
                blocks.value.append((query["blockid"] ?? "", String(decoding: body, as: UTF8.self)))
                return (201, [:], Data())
            }
            XCTAssertEqual(query["comp"], "blocklist")
            commit = request
            return (201, [:], Data())
        }
        let (api, provider) = client()
        provider.singleUploadLimit = 4; provider.blockOverride = 4
        let local = try temporaryRoot().appendingPathComponent("grande.bin")
        try payload.write(to: local)
        var saved: UploadCheckpoint?
        do {
            _ = try await api.resumableUpload(local: local, parent: "fotos/", name: "grande.bin", replacing: nil, checkpoint: nil, save: { saved = $0 }, progress: { _, _ in })
            XCTFail("The second block is refused")
        } catch {}
        XCTAssertEqual(saved?.offset, 4)
        let receipt = try await api.resumableUpload(local: local, parent: "fotos/", name: "grande.bin", replacing: nil, checkpoint: saved,
                                                    save: { saved = $0 }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .verified, "Azure checked every block against its MD5")
        XCTAssertEqual(blocks.value.map(\.body), ["0123", "4567", "89"], "The first block went once")
        let ids = blocks.value.map(\.id)
        XCTAssertEqual(Set(ids.map(\.count)).count, 1, "Block ids of one blob share a length")
        let list = String(decoding: requestData(try XCTUnwrap(commit)), as: UTF8.self)
        XCTAssertEqual(list, #"<?xml version="1.0" encoding="utf-8"?><BlockList>"# + ids.map { "<Latest>\($0)</Latest>" }.joined() + "</BlockList>")
        XCTAssertEqual(commit?.value(forHTTPHeaderField: "x-ms-blob-content-md5"), Data(Insecure.MD5.hash(data: payload)).base64EncodedString(),
                       "The whole file's MD5 survives the resume")
        XCTAssertEqual(commit?.value(forHTTPHeaderField: "If-None-Match"), "*", "A new blob never overwrites one already there")
        XCTAssertEqual(saved?.complete, true)
        XCTAssertNil(saved?.sessionID)
    }

    func testASmallUploadIsOnePutBlobCheckedAgainstTheAnsweredMD5() async throws {
        let payload = Data("hola".utf8)
        let md5 = Data(Insecure.MD5.hash(data: payload)).base64EncodedString()
        StubProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-blob-type"), "BlockBlob")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-MD5"), md5)
            return (201, ["Content-MD5": md5], Data())
        }
        let (api, _) = client()
        let local = try temporaryRoot().appendingPathComponent("nota.txt")
        try payload.write(to: local)
        let receipt = try await api.resumableUpload(local: local, parent: "fotos/", name: "nota.txt", replacing: nil, checkpoint: nil, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(receipt.verification, .verified)
        XCTAssertEqual(receipt.remoteID, "fotos/nota.txt")
    }

    func testARangedDownloadIsAssembledAndCheckedAgainstContentMD5() async throws {
        let payload = Data("0123456789".utf8)
        let ranges = Box<[String]>([])
        StubProtocol.handler = { request in
            let range = request.value(forHTTPHeaderField: "x-ms-range") ?? ""
            ranges.value.append(range)
            let bounds = range.dropFirst(6).split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(ranges.value.count == 1 ? nil : request.value(forHTTPHeaderField: "If-Match"), ranges.value.count == 1 ? nil : "\"etag1\"",
                           "Later pieces are pinned to the first one's version")
            return (206, ["ETag": "\"etag1\""], payload.subdata(in: bounds[0]..<(bounds[1] + 1)))
        }
        let (api, provider) = client()
        provider.downloadPiece = 4
        let hex = Insecure.MD5.hash(data: payload).map { String(format: "%02x", $0) }.joined()
        let file = CloudFile(id: "fotos/a.bin", name: "a.bin", mime: "application/octet-stream", size: 10, modified: nil, webURL: nil, isFolder: false,
                             checksum: ContentHash(algorithm: .md5, value: hex))
        let destination = try temporaryRoot().appendingPathComponent("a.bin")
        let verification = try await api.download(file: file, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        XCTAssertEqual(ranges.value, ["bytes=0-3", "bytes=4-7", "bytes=8-9"])
        XCTAssertEqual(verification, .verified)
    }

    func testAMoveWaitsForAPendingCopyBeforeDeletingTheSource() async throws {
        let log = Box<[String]>([])
        let heads = Box(0)
        StubProtocol.handler = { request in
            let method = request.httpMethod ?? "", path = request.url!.path
            log.value.append(method + " " + path)
            switch method {
            case "HEAD" where path == "/fotos/nuevo.jpg":
                heads.value += 1
                // The first HEAD is the check that the name is free; then the copy is followed.
                if heads.value == 1 { return (404, [:], Data()) }
                return (200, ["x-ms-copy-status": heads.value < 3 ? "pending" : "success", "Content-Length": "1"], Data())
            case "PUT":
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-ms-copy-source"), "https://cuenta.blob.core.windows.net/fotos/viejo.jpg")
                return (202, ["x-ms-copy-status": "pending"], Data())
            case "DELETE": return (202, [:], Data())
            default: XCTFail("Unexpected \(method) \(path)"); return (500, [:], Data())
            }
        }
        let (api, _) = client()
        let file = CloudFile(id: "fotos/viejo.jpg", name: "viejo.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.rename(file: file, name: "nuevo.jpg")
        XCTAssertEqual(log.value.last, "DELETE /fotos/viejo.jpg")
        XCTAssertEqual(heads.value, 3, "The copy was followed until it succeeded")
    }

    func testARejectedKeyExpiresTheSessionAndALinkIsASignedSAS() async throws {
        StubProtocol.handler = { _ in (403, [:], Data("<Error><Code>AuthenticationFailed</Code><Message>Server failed to authenticate the request.</Message></Error>".utf8)) }
        let (api, _) = client()
        do { _ = try await api.list(parent: "root"); XCTFail("Refused") } catch {}
        XCTAssertTrue(api.sessionExpired)

        let (_, linking) = client()
        let file = CloudFile(id: "fotos/playa 1.jpg", name: "playa 1.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        let link = try linking.temporaryLink(for: file, lifetime: 3600)
        XCTAssertEqual(link.host, "cuenta.blob.core.windows.net")
        XCTAssertEqual(link.path, "/fotos/playa 1.jpg")
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["sp"], "r"); XCTAssertEqual(fields["sr"], "b"); XCTAssertNotNil(fields["sig"])
        XCTAssertTrue(Cloud.azure.capabilities.temporaryLinks && !Cloud.azure.capabilities.quota)
    }

    func testTheFormFindsTheEndpointAndRefusesPlainHTTPOverTheInternet() throws {
        var form = AzureSignIn(); form.accountName = "MiCuenta1"
        XCTAssertEqual(try AzureAuthentication.endpoint(for: form).endpoint.url?.absoluteString, "https://micuenta1.blob.core.windows.net")
        form = AzureSignIn(); form.endpoint = "http://127.0.0.1:10000/devstoreaccount1"
        let azurite = try AzureAuthentication.endpoint(for: form)
        XCTAssertEqual(azurite.name, "devstoreaccount1")
        form.endpoint = "http://blobs.example.com"; form.accountName = "x1y"
        XCTAssertThrowsError(try AzureAuthentication.endpoint(for: form))
        form = AzureSignIn(); form.accountName = "a"
        XCTAssertThrowsError(try AzureAuthentication.endpoint(for: form), "Account names have three to twenty-four characters")
    }
}
