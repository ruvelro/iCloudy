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
        // A single endpoint written by hand would silently read the wrong drive, so the check is mechanical, and it
        // covers every source file: the upload and the move were once written outside the two files it looked at.
        let root = URL(fileURLWithPath: "Sources/iCloudy")
        let sources = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.path }.filter { $0.hasSuffix(".swift") })
        XCTAssertGreaterThan(sources.count, 30)
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
                // `about` describes the person, not a drive; it takes no drive parameters.
                if line.contains("www.googleapis.com/drive/v3"), !line.contains("/drives?"), !line.contains("/drive/v3/about") {
                    XCTAssertTrue(line.contains("googleURL(") || scopedNearby,
                                  "\(place) debería pasar por googleURL, googleDriveScope o googleAllDrives")
                }
            }
        }
    }

    private func stubbed(_ account: Account) -> CloudAPI {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: account, session: URLSession(configuration: configuration), tokenProvider: { "token" })
    }

    func testUploadingToTheTopOfASharedDriveFilesItThereAndNotUnderMiUnidad() async throws {
        // Drive accepts the alias "root" with supportsAllDrives and files the upload in the person's own drive, so
        // a file dropped at the top of a shared drive vanished from it. The parent has to be the drive's id.
        let api = stubbed(Account.scoped(to: "0ABCdrive", named: "Marketing", from: account(.google)))
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("hola".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        var startBody = ""
        StubProtocol.handler = { request in
            // The session starts with a POST; the bytes follow with a PUT to the Location handed back.
            if request.httpMethod == "POST" {
                XCTAssertTrue(request.url?.query?.contains("supportsAllDrives=true") == true, request.url?.absoluteString ?? "")
                startBody = requestBody(request)
                return (200, ["Location": "https://www.googleapis.com/upload/session/1"], Data())
            }
            return (200, [:], Data(#"{"id":"nuevo","md5Checksum":"4d186321c1a7f0f354b297e8914ab240"}"#.utf8))
        }
        let checkpoint = UploadCheckpoint(total: 4, modified: try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let receipt = try await api.resumableUpload(local: source, parent: "root", name: "hola.txt", replacing: nil, checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertTrue(startBody.contains(#""parents":["0ABCdrive"]"#), startBody)
        XCTAssertEqual(receipt.remoteID, "nuevo")

        // An ordinary account keeps sending the alias, which is what Drive expects there.
        StubProtocol.handler = { request in
            if request.httpMethod == "POST" { startBody = requestBody(request); return (200, ["Location": "https://www.googleapis.com/upload/session/2"], Data()) }
            return (200, [:], Data(#"{"id":"nuevo"}"#.utf8))
        }
        _ = try await stubbed(account(.google)).resumableUpload(local: source, parent: "root", name: "hola.txt", replacing: nil, checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertTrue(startBody.contains(#""parents":["root"]"#), startBody)
    }

    func testMovingInsideASharedDriveOptsInOnThePatchToo() async throws {
        // The PATCH that changes the parents was the one Drive call built by hand, without supportsAllDrives, and
        // Drive answers that with 404 for anything living in a shared drive.
        let api = stubbed(Account.scoped(to: "0ABCdrive", named: "Marketing", from: account(.google)))
        var patch: URL?
        StubProtocol.handler = { request in
            if request.httpMethod == "PATCH" { patch = request.url; return (200, [:], Data(#"{"id":"f1","parents":["dest"]}"#.utf8)) }
            return (200, [:], Data(#"{"parents":["old"]}"#.utf8))
        }
        let file = CloudFile(id: "f1", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.move(file: file, to: "dest")
        let query = URLComponents(url: try XCTUnwrap(patch), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "supportsAllDrives" }?.value, "true", patch?.absoluteString ?? "")
        XCTAssertEqual(query.first { $0.name == "addParents" }?.value, "dest")
        XCTAssertEqual(query.first { $0.name == "removeParents" }?.value, "old")
    }

    func testSearchingAsksForOneCorpusNotTwo() async throws {
        // A scoped account once sent `corpora=user` and `corpora=drive` in the same request, which Drive rejects.
        var seen: [URL] = []
        StubProtocol.handler = { request in seen.append(request.url!); return (200, [:], Data(#"{"files":[]}"#.utf8)) }
        _ = try await stubbed(Account.scoped(to: "0ABCdrive", named: "Marketing", from: account(.google))).searchPage(term: "informe")
        _ = try await stubbed(account(.google)).searchPage(term: "informe")
        let corpora = seen.map { URLComponents(url: $0, resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name == "corpora" }.map { $0.value ?? "" } }
        XCTAssertEqual(corpora, [["drive"], ["user"]])
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
