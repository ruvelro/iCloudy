import XCTest
@testable import iCloudy

final class OAuthTests: XCTestCase {
    func testMicrosoftRequestsOneDriveWithoutMailPermissions() {
        let url = OAuthRequest.authorizationURL(cloud: .microsoft, clientID: "test-client", state: "state", challenge: "challenge")
        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertTrue(url.path.hasPrefix("/common/"))
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let scope = query.first { $0.name == "scope" }!.value!
        XCTAssertTrue(scope.contains("Files.ReadWrite"))
        XCTAssertTrue(scope.contains("offline_access"))
        XCTAssertFalse(scope.contains("Mail."))
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(query.first { $0.name == "redirect_uri" }?.value, OAuthRequest.redirectURI)
        XCTAssertFalse(query.contains { $0.name == "client_secret" })
    }

    func testGoogleRequestsOfflineDriveAccessAndAccountSelection() {
        let url = OAuthRequest.authorizationURL(cloud: .google, clientID: "test-client", state: "state", challenge: "challenge")
        XCTAssertEqual(url.host, "accounts.google.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "access_type" }?.value, "offline")
        XCTAssertEqual(query.first { $0.name == "prompt" }?.value, "consent select_account")
        XCTAssertTrue(query.first { $0.name == "scope" }!.value!.contains("https://www.googleapis.com/auth/drive"))
        XCTAssertFalse(query.contains { $0.name == "client_secret" })
    }

    func testCallbackRejectsWrongStateDuplicateParametersAndWrongPath() throws {
        XCTAssertEqual(try OAuthRequest.callbackCode(target: "/callback?code=a%2Bb&state=expected", expectedState: "expected"), "a+b")
        for target in ["/callback?code=valid&state=attacker", "/callback?code=valid", "/wrong?code=valid&state=expected", "/callback?code=valid&state=expected&state=expected", "/callback?code=one&code=two&state=expected", "/callback?code=&state=expected", "/callback?error=access_denied&state=expected"] {
            XCTAssertThrowsError(try OAuthRequest.callbackCode(target: target, expectedState: "expected"), target)
        }
    }

    func testUnconfiguredBuildCannotStartAuthorization() {
        let config = OAuthConfiguration(googleClientID: "", googleDesktopClientSecret: "", microsoftClientID: "")
        XCTAssertThrowsError(try config.client(for: .google))
        XCTAssertThrowsError(try config.client(for: .microsoft))
    }

    func testInstalledConfigurationNeverSendsGoogleSecretToMicrosoft() throws {
        let config = OAuthConfiguration(googleClientID: "1234567890-example.apps.googleusercontent.com", googleDesktopClientSecret: "desktop-metadata", microsoftClientID: "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(try config.client(for: .google).secret, "desktop-metadata")
        XCTAssertEqual(try config.client(for: .microsoft).secret, "")
        let data = try PropertyListEncoder().encode(config)
        XCTAssertEqual(try PropertyListDecoder().decode(OAuthConfiguration.self, from: data).microsoftClientID, config.microsoftClientID)
    }
}
