import XCTest
@testable import iCloudy

final class StorageTests: XCTestCase {
    func testGoogleUsesAccountWideUsageRatherThanDriveOnly() throws {
        let quota = try StorageQuota.parse(["storageQuota": ["usage": "12000000000", "usageInDrive": "1000", "limit": "15000000000"]], cloud: .google)
        XCTAssertEqual(quota.used, 12_000_000_000)
        XCTAssertEqual(quota.total, 15_000_000_000)
        XCTAssertEqual(quota.fraction!, 0.8, accuracy: 0.0001)
    }

    func testGoogleBreakdownSeparatesFilesTrashAndOtherServices() throws {
        let quota = try StorageQuota.parse(["storageQuota": ["usage": "1000", "usageInDrive": "600", "usageInDriveTrash": "100", "limit": "2000"]], cloud: .google)
        XCTAssertEqual(quota.files, 600); XCTAssertEqual(quota.trash, 100)
        let segments = quota.segments
        XCTAssertEqual(segments.map(\.kind), [.files, .trash, .other])
        XCTAssertEqual(segments[0].fraction, 0.25, accuracy: 0.0001, "files without the trash")
        XCTAssertEqual(segments[1].fraction, 0.05, accuracy: 0.0001)
        XCTAssertEqual(segments[2].fraction, 0.20, accuracy: 0.0001, "Gmail, Photos and the rest")
        XCTAssertEqual(segments.reduce(0) { $0 + $1.fraction }, quota.fraction!, accuracy: 0.0001)
        XCTAssertTrue(quota.breakdown.contains("Papelera"))
        XCTAssertTrue(quota.breakdown.contains("Otros servicios"))
        XCTAssertTrue(try StorageQuota.parse(["storageQuota": ["usage": "5"]], cloud: .google).segments.isEmpty, "no total, no pie")
    }

    func testMissingAndZeroLimitNeverInventsAPercentage() throws {
        let unknown = try StorageQuota.parse(["storageQuota": ["usage": "0"]], cloud: .google)
        XCTAssertEqual(unknown.used, 0)
        XCTAssertNil(unknown.total)
        XCTAssertNil(unknown.fraction)
        XCTAssertTrue(unknown.summary.contains("total no disponible"))
        XCTAssertNil(StorageQuota(used: 1, total: 0).fraction)
        XCTAssertEqual(StorageQuota(used: 0, total: 100).fraction, 0)
        XCTAssertEqual(StorageQuota(used: 110, total: 100).fraction, 1)
    }

    func testMicrosoftSupportsNumbersAndRemainingFallback() throws {
        let quota = try StorageQuota.parse(["quota": ["used": 1234, "total": 5000, "deleted": 34]], cloud: .microsoft)
        XCTAssertEqual(quota, StorageQuota(used: 1234, total: 5000, trash: 34))
        XCTAssertEqual(quota.segments.map(\.kind), [.files, .trash])
        XCTAssertEqual(quota.segments[0].fraction, 0.24, accuracy: 0.0001)
        let fallback = try StorageQuota.parse(["quota": ["remaining": 4000, "total": 5000]], cloud: .microsoft)
        XCTAssertEqual(fallback.used, 1000)
        XCTAssertThrowsError(try StorageQuota.parse(["quota": ["remaining": 6000, "total": 5000]], cloud: .microsoft))
    }

    func testMissingMalformedAndNegativeUsageAreNotZero() throws {
        for value: [String: Any] in [[:], ["usage": "oops"], ["usage": "-1"], ["usage": true], ["usage": 1.5]] {
            XCTAssertThrowsError(try StorageQuota.parse(["storageQuota": value], cloud: .google))
        }
        XCTAssertThrowsError(try StorageQuota.parse([:], cloud: .microsoft))
        let quota = try StorageQuota.parse(["storageQuota": ["usage": "2", "limit": "-1"]], cloud: .google)
        XCTAssertNil(quota.total)
    }

    @MainActor func testQuotaRequestsAreAuthenticatedAndReadOnly() async throws {
        defer { StubProtocol.handler = nil }
        for cloud in Cloud.allCases {
            // A volume reports free space from the file system, without any request to authenticate.
            if cloud == .volume {
                StubProtocol.handler = { _ in XCTFail("Un volumen no consulta la cuota por HTTP"); return (500, [:], Data()) }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: folder) }
                let api = CloudAPI(account: Account(id: "volumen", cloud: .volume, name: "V", email: "v", clientID: "", clientSecret: nil,
                                                    serverURL: folder.standardizedFileURL.path))
                let quota = try await api.storageQuota()
                XCTAssertGreaterThan(quota.total ?? 0, 0)
                continue
            }
            // A provider with no quota command is expected to say so instead of inventing a number.
            guard cloud.capabilities.quota else {
                let api = CloudAPI(account: Account(id: "sin-cuota", cloud: cloud, name: "T", email: "t@example.com", clientID: "", clientSecret: nil, serverURL: "ftp://127.0.0.1/"),
                                   tokenProvider: { "quota-token" })
                do { _ = try await api.storageQuota(); XCTFail("\(cloud) no tiene cuota que informar") }
                catch { XCTAssertTrue(error.localizedDescription.contains("espacio disponible"), error.localizedDescription) }
                continue
            }
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let account = Account(id: "quota-test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "test", clientSecret: nil,
                                  serverURL: cloud == .webdav ? "https://dav.example.com/remote.php/dav/files/ana" : nil)
            let api = CloudAPI(account: account, session: session, tokenProvider: { "quota-token" })
            StubProtocol.handler = { request in
                let scheme = cloud == .webdav ? "Basic" : "Bearer"
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "\(scheme) quota-token")
                let url = try XCTUnwrap(request.url)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                switch cloud {
                case .google:
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(url.host, "www.googleapis.com")
                    XCTAssertEqual(url.path, "/drive/v3/about")
                    XCTAssertEqual(query?.first?.value, "storageQuota")
                    return (200, [:], Data(#"{"storageQuota":{"usage":"40","limit":"100"}}"#.utf8))
                case .microsoft:
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(url.host, "graph.microsoft.com")
                    XCTAssertEqual(url.path, "/v1.0/me/drive")
                    XCTAssertEqual(query?.first?.name, "$select")
                    XCTAssertEqual(query?.first?.value, "quota")
                    return (200, [:], Data(#"{"quota":{"used":40,"total":100}}"#.utf8))
                case .dropbox:
                    // Dropbox reads through an RPC, so the method is POST even though nothing is modified.
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(url.host, "api.dropboxapi.com")
                    XCTAssertEqual(url.path, "/2/users/get_space_usage")
                    return (200, [:], Data(#"{"used":40,"allocation":{".tag":"individual","allocated":100}}"#.utf8))
                case .box:
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(url.host, "api.box.com")
                    XCTAssertEqual(url.path, "/2.0/users/me")
                    return (200, [:], Data(#"{"space_used":40,"space_amount":100}"#.utf8))
                case .ftp, .volume:
                    XCTFail("\(cloud) no llega hasta aquí"); return (500, [:], Data())
                case .webdav:
                    XCTAssertEqual(request.httpMethod, "PROPFIND")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Depth"), "0")
                    XCTAssertEqual(url.host, "dav.example.com")
                    XCTAssertEqual(url.path, "/remote.php/dav/files/ana")
                    // The standard reports what is left, not the capacity.
                    return (207, [:], Data(#"""
                    <?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response>
                    <d:href>/remote.php/dav/files/ana/</d:href><d:propstat><d:prop>
                    <d:resourcetype><d:collection/></d:resourcetype>
                    <d:quota-used-bytes>40</d:quota-used-bytes><d:quota-available-bytes>60</d:quota-available-bytes>
                    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>
                    """#.utf8))
                }
            }
            let result = try await api.storageQuota()
            XCTAssertEqual(result.used, 40, "\(cloud)")
            XCTAssertEqual(result.total, 100, "\(cloud)")
            api.invalidate()
            do { _ = try await api.storageQuota(); XCTFail("Disconnected clients must not reuse credentials") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
    }

    @MainActor func testDemoQuotaTracksNestedFilesWithoutConsumingTransferFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let demo = try DemoStore(directory: root)
        let before = try demo.storageQuota()
        let folder = try demo.add(name: "Nested", parent: "root", folder: true)
        _ = try demo.add(name: "file.bin", parent: folder, content: Data(repeating: 1, count: 123))
        demo.failNext = true
        XCTAssertEqual(try demo.storageQuota().used, before.used + 123)
        XCTAssertEqual(before.total, 5_000_000_000)
        XCTAssertTrue(demo.failNext)
        demo.offline = true
        XCTAssertThrowsError(try demo.storageQuota())
    }

    @MainActor func testDisconnectGuardIsScopedToAccountAndWaitsForCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = TransferQueue(storeURL: root.appendingPathComponent("queue.json"))
        let transfer = Transfer(name: "file.bin", destination: "Test", accountID: "busy", direction: .upload, localURL: root.appendingPathComponent("file.bin"))
        try queue.add([transfer])
        XCTAssertTrue(queue.hasActive(accountID: "busy"))
        XCTAssertFalse(queue.hasActive(accountID: "other"))
        queue.cancel(transfer.id, pause: true)
        XCTAssertTrue(queue.hasActive(accountID: "busy"), "Cancellation must settle before disconnecting")
        for _ in 0..<100 where queue.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.isWorking)
        XCTAssertFalse(queue.hasActive(accountID: "busy"))
    }
}
