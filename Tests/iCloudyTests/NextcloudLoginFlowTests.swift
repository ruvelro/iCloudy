import XCTest
@testable import iCloudy

/// Login Flow v2 over the HTTP stub: the login page is opened, the poll waits through 404s, the app password ends up
/// as the account's Basic credential and the files root is the user's id, not the login name.
@MainActor
final class NextcloudLoginFlowTests: XCTestCase {
    private func flow(opened: Box<[URL]>) -> NextcloudLoginFlow {
        var flow = NextcloudLoginFlow(session: stubbedSession())
        flow.openBrowser = { opened.value.append($0) }
        flow.pollInterval = .zero
        return flow
    }

    func testTheInstallationIsFoundFromAnyAddressPeopleCopy() throws {
        XCTAssertEqual(try NextcloudLoginFlow.installation("nube.example.com").url?.absoluteString, "https://nube.example.com")
        XCTAssertEqual(try NextcloudLoginFlow.installation("https://example.com/nextcloud/remote.php/dav/files/ana/").url?.absoluteString,
                       "https://example.com/nextcloud")
        XCTAssertEqual(try NextcloudLoginFlow.installation("https://nube.example.com/index.php/apps/files/").url?.absoluteString, "https://nube.example.com")
        XCTAssertEqual(try NextcloudLoginFlow.installation("http://nas.local:8080").url?.absoluteString, "http://nas.local:8080")
        XCTAssertThrowsError(try NextcloudLoginFlow.installation("http://nube.example.com"), "No plain HTTP over the internet")
    }

    func testTheFlowPollsUntilTheBrowserIsDoneAndStoresTheAppPassword() async throws {
        let polls = Box(0)
        var probe: URLRequest?
        StubProtocol.handler = { request in
            let url = request.url!
            switch (request.httpMethod ?? "", url.path) {
            case ("POST", "/index.php/login/v2"):
                return (200, [:], Data(#"{"poll":{"token":"tok","endpoint":"https://nube.example.com/index.php/login/v2/poll"},"login":"https://nube.example.com/index.php/login/v2/flow/abc"}"#.utf8))
            case ("POST", "/index.php/login/v2/poll"):
                XCTAssertEqual(requestBody(request), "token=tok")
                polls.value += 1
                if polls.value < 3 { return (404, [:], Data()) }
                return (200, [:], Data(#"{"server":"https://nube.example.com","loginName":"ana@example.com","appPassword":"secreto-de-app"}"#.utf8))
            case ("GET", "/ocs/v2.php/cloud/user"):
                XCTAssertEqual(request.value(forHTTPHeaderField: "OCS-APIRequest"), "true")
                return (200, [:], Data(#"{"ocs":{"data":{"id":"ana"}}}"#.utf8))
            case ("PROPFIND", _):
                probe = request
                return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>"#.utf8))
            default:
                XCTFail("Unexpected \(request.httpMethod ?? "") \(url)"); return (500, [:], Data())
            }
        }
        let opened = Box<[URL]>([])
        let (account, credential) = try await flow(opened: opened).signIn(server: "nube.example.com")
        XCTAssertEqual(opened.value.map(\.absoluteString), ["https://nube.example.com/index.php/login/v2/flow/abc"])
        XCTAssertEqual(polls.value, 3, "It keeps asking while the server answers 404")
        XCTAssertEqual(account.serverURL, "https://nube.example.com/remote.php/dav/files/ana", "Files live under the user id")
        XCTAssertEqual(account.flavor, "nextcloud")
        XCTAssertEqual(credential.accessToken, Data("ana@example.com:secreto-de-app".utf8).base64EncodedString())
        XCTAssertEqual(probe?.url?.path, "/remote.php/dav/files/ana", "The account is checked like any WebDAV sign-in")
    }

    func testALoginPageOnAnotherHostIsNeverOpened() async throws {
        StubProtocol.handler = { _ in
            (200, [:], Data(#"{"poll":{"token":"t","endpoint":"https://nube.example.com/poll"},"login":"https://phish.example.net/login"}"#.utf8))
        }
        let opened = Box<[URL]>([])
        do {
            _ = try await flow(opened: opened).signIn(server: "nube.example.com")
            XCTFail("A login page elsewhere must be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("phish.example.net"))
        }
        XCTAssertTrue(opened.value.isEmpty)
    }

    func testAServerWithoutTheFlowSaysSoAndAnExpiredTokenEnds() async throws {
        StubProtocol.handler = { _ in (404, [:], Data("<html/>".utf8)) }
        let opened = Box<[URL]>([])
        do { _ = try await flow(opened: opened).signIn(server: "dav.example.com"); XCTFail("No flow, no sign-in") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Usuario y contraseña")) }

        var expiring = flow(opened: opened)
        expiring.lifetime = .zero
        do { _ = try await expiring.wait(poll: URL(string: "https://nube.example.com/poll")!, token: "t"); XCTFail("Expired") }
        catch { XCTAssertTrue(error.localizedDescription.contains("caducó")) }
    }
}
