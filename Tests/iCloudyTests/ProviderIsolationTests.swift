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
}
