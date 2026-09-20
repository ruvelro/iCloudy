import XCTest
@testable import iCloudy

@MainActor
final class ProviderIsolationTests: XCTestCase {
    private func client(_ cloud: Cloud, driveID: String? = nil) -> CloudAPI {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        var account = Account(id: "isolation-\(cloud.rawValue)", cloud: cloud, name: "Test", email: "", clientID: "", clientSecret: nil)
        account.options["driveID"] = driveID
        return CloudAPI(account: account, session: URLSession(configuration: configuration), tokenProvider: { "test" })
    }

    func testInterleavedListingsKeepProviderRoutesAndSharedDriveScopesSeparate() async throws {
        var hosts: [String] = []
        StubProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            hosts.append(try XCTUnwrap(url.host))
            if url.host == "www.googleapis.com" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                XCTAssertEqual(query.first { $0.name == "driveId" }?.value, "team-google")
                XCTAssertTrue(query.first { $0.name == "q" }?.value?.contains("'team-google' in parents") == true)
                return (200, [:], Data(#"{"files":[{"id":"g","name":"Google","mimeType":"text/plain"}]}"#.utf8))
            }
            XCTAssertEqual(url.path, "/v1.0/drives/team-microsoft/root/children")
            return (200, [:], Data(#"{"value":[{"id":"m","name":"Microsoft","file":{"mimeType":"text/plain"}}]}"#.utf8))
        }
        defer { StubProtocol.handler = nil }
        let google = client(.google, driveID: "team-google")
        let microsoft = client(.microsoft, driveID: "team-microsoft")
        let first = try await google.list(parent: "root")
        let second = try await microsoft.list(parent: "root")
        let third = try await google.list(parent: "root")
        XCTAssertEqual(first.map(\.id), ["g"])
        XCTAssertEqual(second.map(\.id), ["m"])
        XCTAssertEqual(third, first)
        XCTAssertEqual(hosts, ["www.googleapis.com", "graph.microsoft.com", "www.googleapis.com"])
    }

    func testInvalidatingOneClientDoesNotInvalidateAnotherForTheSameAccount() async throws {
        let first = client(.google), second = client(.google)
        first.invalidate()
        XCTAssertTrue(first.invalidated)
        XCTAssertFalse(second.invalidated)
        do { _ = try await first.token(); XCTFail("An invalidated client must stop authenticating") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let token = try await second.token()
        XCTAssertEqual(token, "test")
    }

    func testMegaCachesBelongToTheirProviderAndAreClearedIndependently() throws {
        let first = client(.mega), second = client(.mega)
        let a = try XCTUnwrap(first.provider as? MegaProvider)
        let b = try XCTUnwrap(second.provider as? MegaProvider)
        a.megaStateCache = MegaState(sid: "first", masterKey: Data(repeating: 1, count: 16))
        b.megaStateCache = MegaState(sid: "second", masterKey: Data(repeating: 2, count: 16))
        a.megaStateCache?.loaded = true
        b.megaStateCache?.loaded = true
        first.dropCaches()
        XCTAssertFalse(try XCTUnwrap(a.megaStateCache).loaded)
        XCTAssertTrue(try XCTUnwrap(b.megaStateCache).loaded)
        first.invalidate()
        XCTAssertNil(a.megaStateCache)
        XCTAssertEqual(b.megaStateCache?.sid, "second")
    }

    func testExpirationCallbacksAreForwardedOnceAndStayWithTheirAccount() {
        let first = client(.o2), second = client(.o2)
        var reasons: [String?] = []
        first.sessionDidExpire = { reasons.append($0) }
        first.provider.expireSession("expired")
        first.provider.expireSession("again")
        XCTAssertEqual(reasons.count, 1)
        XCTAssertEqual(reasons.first!, "expired")
        XCTAssertTrue(first.sessionExpired)
        XCTAssertFalse(second.sessionExpired)
    }
}
