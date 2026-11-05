import XCTest
import CryptoKit
@testable import iCloudy

/// What every provider shares: capabilities, actions, sign-in URLs, configuration and token renewal.
@MainActor
final class ProviderCommonTests: XCTestCase {
    private func client(_ cloud: Cloud, server: String? = nil) -> CloudAPI {
        makeStubbedClient(cloud, server: server ?? (cloud == .webdav ? "https://dav.example.com/remote.php/dav/files/ana" : nil))
    }
    private func temporaryFile(_ payload: Data) throws -> URL {
        let url = try temporaryRoot().appendingPathComponent("payload")
        try payload.write(to: url)
        return url
    }

    func testATokenThatExpiresMidUploadIsRenewedInsteadOfFailingTheTransfer() async throws {
        // The block uploads of Dropbox and Box go straight to their own hosts, outside the path that renews a token
        // after a 401. A long upload that crossed the hour failed with a bare "HTTP 401".
        let payload = Data(repeating: 4, count: 1024)
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = UploadHasher.hex(SHA256.hash(data: Data(SHA256.hash(data: payload))))
        let store = MemoryCredentials()
        store.stored["dropbox:1"] = Credential(accessToken: "viejo", refreshToken: "r1", expires: Date().addingTimeInterval(3600))
        var refreshes = 0, unauthorized = 0
        StubProtocol.handler = { request in
            if request.url?.host == "api.dropboxapi.com", request.url?.path == "/oauth2/token" {
                refreshes += 1
                return (200, [:], Data(#"{"access_token":"nuevo","refresh_token":"r2","expires_in":3600}"#.utf8))
            }
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer viejo", request.url!.path.hasSuffix("append_v2") {
                unauthorized += 1
                return (401, [:], Data())
            }
            if request.url!.path.hasSuffix("start") { return (200, [:], Data(#"{"session_id":"s1"}"#.utf8)) }
            if request.url!.path.hasSuffix("append_v2") { return (200, [:], Data()) }
            return (200, [:], Data(#"{"path_lower":"/x","content_hash":"\#(expected)"}"#.utf8))
        }
        let config = StubProtocol.configuration()
        let account = Account(id: "dropbox:1", cloud: .dropbox, name: "Ana", email: "ana@ejemplo.com", clientID: "c", clientSecret: nil)
        let api = CloudAPI(account: account, session: URLSession(configuration: config), credentials: store)
        let stamp = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let receipt = try await api.resumableUpload(local: file, parent: "/", name: "x", replacing: nil,
                                                    checkpoint: UploadCheckpoint(total: 1024, modified: stamp), save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(unauthorized, 1)
        XCTAssertEqual(refreshes, 1, "Se renueva una vez y el bloque se repite")
        XCTAssertEqual(receipt.remoteID, "/x")
        XCTAssertFalse(api.sessionExpired)
    }

    func testCapabilitiesDescribeWhatEachProviderCanDo() {
        XCTAssertTrue(Cloud.google.capabilities.exportsDocuments)
        XCTAssertFalse(Cloud.dropbox.capabilities.exportsDocuments)
        XCTAssertTrue(Cloud.dropbox.capabilities.reversibleTrash, "Dropbox keeps deleted files recoverable")
        XCTAssertFalse(Cloud.webdav.capabilities.reversibleTrash, "Plain WebDAV deletes for good")
        XCTAssertTrue(Cloud.webdav.capabilities.search, "iCloudy recorre el árbol")
        XCTAssertFalse(Cloud.webdav.capabilities.oauth)
        XCTAssertFalse(Cloud.box.capabilities.recents)
        XCTAssertTrue(Cloud.microsoft.capabilities.sharedWithMe)
        XCTAssertEqual(Cloud.box.rootAlias, "0")
        XCTAssertEqual(Cloud.dropbox.rootAlias, "")
        XCTAssertEqual(Cloud.webdav.authorizationScheme, "Basic")
        XCTAssertEqual(Cloud.google.authorizationScheme, "Bearer")
    }

    func testActionsDependOnTheKindOfItemAndTheRefusalIsExplainedBeforehand() {
        // Mega was offered "copy" and "public link" for folders, and O2 a link for single files and a permanent delete
        // for folders, only for the provider to refuse each one after the request had gone out.
        func account(_ cloud: Cloud) -> Account {
            Account(id: "\(cloud.rawValue):ana", cloud: cloud, name: "Ana", email: "ana@ejemplo.com", clientID: "", clientSecret: nil)
        }
        let folder = CloudFile(id: "d", name: "Fotos", mime: "", size: nil, modified: nil, webURL: nil, isFolder: true)
        let file = CloudFile(id: "f", name: "a.pdf", mime: "application/pdf", size: 1, modified: nil, webURL: nil, isFolder: false)

        let mega = account(.mega)
        XCTAssertTrue(mega.capabilities.allows(.copy, on: [file]))
        XCTAssertFalse(mega.capabilities.allows(.copy, on: [file, folder]), "One folder in the selection is enough")
        XCTAssertEqual(mega.limitation(.copy, for: [folder]), L("Mega solo copia archivos, no carpetas."))
        XCTAssertNil(mega.limitation(.publicLink, for: [file]))
        XCTAssertTrue(mega.limitation(.publicLink, for: [folder])?.contains("mega.nz") == true)
        XCTAssertNil(mega.limitation(.permanentDelete, for: [folder]))

        let o2 = account(.o2)
        XCTAssertNil(o2.limitation(.publicLink, for: [folder]))
        XCTAssertEqual(o2.limitation(.publicLink, for: [file]), L("O2 Cloud crea enlaces de carpetas. Para un archivo suelto, compártelo desde su web."))
        XCTAssertNil(o2.limitation(.permanentDelete, for: [file]))
        XCTAssertNotNil(o2.limitation(.permanentDelete, for: [folder]))
        XCTAssertNotNil(o2.limitation(.copy, for: [file]), "O2 has no copy at all")

        let google = account(.google)
        XCTAssertEqual(google.limitation(.copy, for: [folder]), L("Google Drive no permite copiar carpetas. Copia los archivos que contiene."))
        XCTAssertNil(google.limitation(.copy, for: [file]))
        XCTAssertNil(google.limitation(.publicLink, for: [folder]))

        // Providers without the restriction, and the demo, offer everything to both kinds.
        for cloud in [Cloud.microsoft, .dropbox, .box] {
            for action in [ItemAction.copy, .publicLink, .permanentDelete] {
                XCTAssertNil(account(cloud).limitation(action, for: [file, folder]), "\(cloud) \(action)")
            }
        }
        XCTAssertNil(Account.demo.limitation(.copy, for: [folder]))
        XCTAssertNotNil(account(.ftp).limitation(.publicLink, for: [file]), "No links at all is still a reason")
    }

    func testAuthorizationURLsMatchEachProvidersEndpoint() {
        let dropbox = OAuthRequest.authorizationURL(cloud: .dropbox, clientID: "key", state: "s", challenge: "c")
        let query = URLComponents(url: dropbox, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(dropbox.host, "www.dropbox.com")
        XCTAssertEqual(query.first { $0.name == "token_access_type" }?.value, "offline", "Without this Dropbox returns no refresh token")
        XCTAssertEqual(query.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNil(query.first { $0.name == "prompt" }, "Dropbox rejects Google's prompt parameter")
        let box = OAuthRequest.authorizationURL(cloud: .box, clientID: "key", state: "s", challenge: "c")
        XCTAssertEqual(box.host, "account.box.com")
        XCTAssertEqual(URLComponents(url: box, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "redirect_uri" }?.value, OAuthRequest.redirectURI)
    }
}
