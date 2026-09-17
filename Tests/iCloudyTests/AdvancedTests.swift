import XCTest
@testable import iCloudy

/// The "advanced" providers: accounts scoped to a Google shared drive or a SharePoint library, and Nextcloud's own
/// sharing API on top of WebDAV. None of them is a new protocol; each is a narrow change to requests already covered
/// elsewhere, so what matters here is that the change reaches every call and never leaks into ordinary accounts.
@MainActor
final class AdvancedTests: XCTestCase {
    private func account(_ cloud: Cloud, options: [String: String] = [:]) -> Account {
        Account(id: "cuenta", cloud: cloud, name: "Ana", email: "ana@ejemplo.com", clientID: "id", clientSecret: nil,
                serverURL: "https://nube.ejemplo.com/remote.php/dav/files/ana", bookmark: nil, options: options)
    }

    func testAScopedAccountBorrowsTheParentCredentialInsteadOfSigningInAgain() throws {
        let parent = account(.google)
        let scoped = Account.scoped(to: "0ABCdrive", named: "Marketing", from: parent)
        XCTAssertEqual(scoped.driveID, "0ABCdrive")
        XCTAssertEqual(scoped.credentialKey, parent.id, "El token vive en la entrada del Llavero de la cuenta madre")
        XCTAssertEqual(parent.credentialKey, parent.id, "Una cuenta normal usa su propio identificador")
        XCTAssertEqual(scoped.cloud, parent.cloud)
        XCTAssertTrue(scoped.id.hasPrefix(parent.id + "/"), "El identificador deja ver de qué cuenta procede")
        XCTAssertNil(parent.driveID)
    }

    func testGoogleCallsOfAScopedAccountOptInToSharedDrives() {
        let plain = CloudAPI(account: account(.google))
        let scoped = CloudAPI(account: Account.scoped(to: "0ABCdrive", named: "Marketing", from: account(.google)))
        let base = "https://www.googleapis.com/drive/v3/files/abc?fields=id"

        XCTAssertEqual(plain.googleURL(base).absoluteString, base, "Una cuenta normal no cambia de dirección")
        XCTAssertTrue(scoped.googleURL(base).absoluteString.contains("supportsAllDrives=true"))
        XCTAssertTrue(scoped.googleURL(base).absoluteString.contains("fields=id"), "Los parámetros originales se conservan")

        XCTAssertTrue(plain.googleDriveScope.isEmpty)
        let scope = Dictionary(uniqueKeysWithValues: scoped.googleDriveScope.map { ($0.name, $0.value) })
        XCTAssertEqual(scope["corpora"], "drive")
        XCTAssertEqual(scope["driveId"], "0ABCdrive")
        XCTAssertEqual(scope["includeItemsFromAllDrives"], "true")
        XCTAssertEqual(scope["supportsAllDrives"], "true")

        // The top level of a shared drive is addressed by the drive's own id, not by the alias "root".
        XCTAssertEqual(scoped.googleParent("root"), "0ABCdrive")
        XCTAssertEqual(plain.googleParent("root"), "root")
        XCTAssertEqual(scoped.googleParent("1xyz"), "1xyz", "Una carpeta concreta se pide igual en los dos casos")
    }

    func testMicrosoftCallsOfAScopedAccountTargetTheLibraryAndNotThePersonalDrive() {
        let plain = CloudAPI(account: account(.microsoft))
        let scoped = CloudAPI(account: Account.scoped(to: "b!raro/ID", named: "Documentos", from: account(.microsoft)))
        XCTAssertEqual(plain.graphDrive, "https://graph.microsoft.com/v1.0/me/drive")
        XCTAssertTrue(scoped.graphDrive.hasPrefix("https://graph.microsoft.com/v1.0/drives/"))
        XCTAssertFalse(scoped.graphDrive.contains("/me/drive"))
        XCTAssertFalse(scoped.graphDrive.contains("b!raro/ID"), "El identificador viaja escapado, no crudo en la ruta")
        XCTAssertTrue(scoped.graphDrive.contains("b%21raro%2FID"))
    }

    func testEveryGoogleAndGraphCallGoesThroughTheScopedHelpers() throws {
        // A single endpoint written by hand would silently read the wrong drive, so the check is mechanical.
        let sources = ["Sources/iCloudy/CloudAPI.swift", "Sources/iCloudy/Providers/SharedDrives.swift"]
        for path in sources {
            let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (number, line) in lines.enumerated() {
                let place = "\(path):\(number + 1)"
                // The helpers themselves are the one place allowed to name the unscoped endpoints.
                guard !line.contains("account.driveID") else { continue }
                // A URL built with URLComponents adds the scope when its query items are set, a few lines below.
                let nearby = lines[number..<min(number + 12, lines.count)].joined()
                let scopedNearby = nearby.contains("googleDriveScope") || nearby.contains("googleAllDrives")

                XCTAssertFalse(line.contains("graph.microsoft.com/v1.0/me/drive"), "\(place) debería usar graphDrive")
                if line.contains("www.googleapis.com/drive/v3"), !line.contains("/drives?") {
                    XCTAssertTrue(line.contains("googleURL(") || scopedNearby,
                                  "\(place) debería pasar por googleURL, googleDriveScope o googleAllDrives")
                }
            }
        }
    }

    func testOnlyNextcloudFlavouredWebDAVOffersPublicLinks() async throws {
        XCTAssertFalse(account(.webdav).capabilities.publicLinks, "WebDAV por sí solo no sabe compartir")
        XCTAssertTrue(account(.webdav, options: ["flavor": "nextcloud"]).capabilities.publicLinks)
        XCTAssertFalse(account(.ftp, options: ["flavor": "nextcloud"]).capabilities.publicLinks, "La marca no vale para otro protocolo")

        let file = CloudFile(id: "/nota.txt", name: "nota.txt", mime: "text/plain", size: 4, modified: nil, webURL: nil, isFolder: false)
        do {
            _ = try await CloudAPI(account: account(.webdav)).publicLink(for: file)
            XCTFail("Un servidor WebDAV cualquiera debe avisar en vez de intentarlo")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no admite enlaces públicos"), error.localizedDescription)
        }
    }

    func testTheSharingEndpointSitsBesideTheWebDAVPathAndNotInsideIt() throws {
        let api = CloudAPI(account: account(.webdav, options: ["flavor": "nextcloud"]))
        let url = try api.nextcloudSharesURL()
        XCTAssertEqual(url.absoluteString, "https://nube.ejemplo.com/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json")

        // A Nextcloud installed in a subdirectory keeps that prefix; cutting at the host would miss it.
        var inSubdirectory = account(.webdav, options: ["flavor": "nextcloud"])
        inSubdirectory.serverURL = "https://ejemplo.com/nube/remote.php/dav/files/ana"
        let nested = try CloudAPI(account: inSubdirectory).nextcloudSharesURL()
        XCTAssertEqual(nested.path, "/nube/ocs/v2.php/apps/files_sharing/api/v1/shares")
    }

    func testAccountsSavedBeforeOptionsExistedStillLoad() throws {
        let old = #"{"id":"vieja","cloud":"webdav","name":"Ana","email":"ana@ejemplo.com","clientID":"id"}"#
        let account = try JSONDecoder().decode(Account.self, from: Data(old.utf8))
        XCTAssertTrue(account.options.isEmpty)
        XCTAssertNil(account.driveID)
        XCTAssertNil(account.flavor)
        XCTAssertEqual(account.credentialKey, "vieja", "Sin opciones, la credencial sigue donde estaba")

        let saved = try JSONEncoder().encode(Account.scoped(to: "0ABC", named: "Marketing", from: account))
        let restored = try JSONDecoder().decode(Account.self, from: saved)
        XCTAssertEqual(restored.driveID, "0ABC")
        XCTAssertEqual(restored.credentialKey, "vieja")
    }
}
