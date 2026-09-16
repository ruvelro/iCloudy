import XCTest
@testable import iCloudy

final class StorageTests: XCTestCase {
    func testGoogleUsesAccountWideUsageRatherThanDriveOnly() throws {
        let quota = try StorageQuota.parse(["storageQuota": ["usage": "12000000000", "usageInDrive": "1000", "limit": "15000000000"]], cloud: .google)
        XCTAssertEqual(quota.used, 12_000_000_000)
        XCTAssertEqual(quota.total, 15_000_000_000)
        XCTAssertEqual(quota.fraction!, 0.8, accuracy: 0.0001)
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
        XCTAssertEqual(quota, StorageQuota(used: 1234, total: 5000))
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
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [StubProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let account = Account(id: "quota-test", cloud: cloud, name: "Test", email: "test@example.com", clientID: "test", clientSecret: nil)
            let api = CloudAPI(account: account, session: session, tokenProvider: { "quota-token" })
            StubProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer quota-token")
                XCTAssertNil(request.httpBody)
                let url = try XCTUnwrap(request.url)
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                if cloud == .google {
                    XCTAssertEqual(url.host, "www.googleapis.com")
                    XCTAssertEqual(url.path, "/drive/v3/about")
                    XCTAssertEqual(query?.first?.value, "storageQuota")
                    return (200, [:], Data(#"{"storageQuota":{"usage":"40","limit":"100"}}"#.utf8))
                }
                XCTAssertEqual(url.host, "graph.microsoft.com")
                XCTAssertEqual(url.path, "/v1.0/me/drive")
                XCTAssertEqual(query?.first?.name, "$select")
                XCTAssertEqual(query?.first?.value, "quota")
                return (200, [:], Data(#"{"quota":{"used":40,"total":100}}"#.utf8))
            }
            let result = try await api.storageQuota()
            XCTAssertEqual(result, StorageQuota(used: 40, total: 100))
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
