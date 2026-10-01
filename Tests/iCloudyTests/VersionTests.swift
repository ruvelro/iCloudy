import XCTest
@testable import iCloudy

/// File version history, provider by provider: what is asked for, how the answer is read, how a version's bytes are
/// fetched and checked, and what a restore sends and leaves behind.
@MainActor
final class VersionTests: XCTestCase {
    private struct Seen { let method: String; let host: String; let path: String; let query: [String: String]; let body: String; let headers: [String: String] }
    private var seen: [Seen] = []
    override func setUp() { seen = [] }
    override func tearDown() { StubProtocol.handler = nil }

    private func client(_ cloud: Cloud, server: String? = nil, nextcloud: Bool = false) -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "test-\(cloud.rawValue)", cloud: cloud, name: "Test", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: server ?? (cloud == .webdav ? "https://nube.example.com/remote.php/dav/files/ana" : nil), bookmark: nil,
                              options: nextcloud ? ["flavor": "nextcloud"] : [:])
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func item(_ id: String, name: String = "informe.pdf", mime: String = "application/pdf", modified: Date? = nil) -> CloudFile {
        CloudFile(id: id, name: name, mime: mime, size: 5, modified: modified, webURL: nil, isFolder: false)
    }
    private func serve(_ answer: @escaping (URLRequest, Seen) -> (Int, [String: String], Data)) {
        StubProtocol.handler = { [self] request in
            let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            let entry = Seen(method: request.httpMethod ?? "", host: parts.host ?? "", path: parts.percentEncodedPath, query: query,
                             body: requestBody(request), headers: request.allHTTPHeaderFields ?? [:])
            seen.append(entry)
            return answer(request, entry)
        }
    }
    private var paths: [String] { seen.map { "\($0.method) \($0.path)" } }
    private func temporaryFile() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("version-test-" + UUID().uuidString) }
    private let abc = Data("abc".utf8)
    private let abcMD5 = "900150983cd24fb0d6963f7d28e17f72"
    private let abcSHA1 = "a9993e364706816aba3e25717850c26c9cd0d89d"

    // MARK: - Capabilities

    func testOnlyProvidersWithAHistoryOfferItAndTheRestSayWhy() async throws {
        for cloud in [Cloud.google, .microsoft, .dropbox, .box] { XCTAssertTrue(cloud.capabilities.versions, "\(cloud)") }
        for cloud in [Cloud.ftp, .sftp, .volume, .mega, .o2, .webdav] { XCTAssertFalse(cloud.capabilities.versions, "\(cloud)") }
        XCTAssertTrue(Cloud.google.capabilities.deletesVersions)
        XCTAssertTrue(Cloud.box.capabilities.deletesVersions)
        XCTAssertFalse(Cloud.microsoft.capabilities.deletesVersions, "Graph no borra versiones sueltas")
        XCTAssertFalse(Cloud.dropbox.capabilities.deletesVersions, "Dropbox tampoco")
        let nextcloud = client(.webdav, nextcloud: true).account
        XCTAssertTrue(nextcloud.capabilities.versions && nextcloud.capabilities.deletesVersions, "Nextcloud sí guarda versiones")
        XCTAssertFalse(Account.demo.capabilities.versions)

        // Every refusal comes with its reason, and nothing reaches the network to find that out.
        StubProtocol.handler = { request in XCTFail("No request expected: \(request.url!)"); return (500, [:], Data()) }
        for cloud in [Cloud.ftp, .mega, .o2, .webdav] {
            let api = client(cloud)
            XCTAssertEqual(api.account.versionsLimitation(for: item("x")), api.account.versionsUnavailable)
            do { _ = try await api.versions(of: item("x")); XCTFail("\(cloud)") }
            catch { XCTAssertEqual(error.localizedDescription, api.account.versionsUnavailable) }
        }
        XCTAssertTrue(client(.webdav).account.versionsUnavailable.contains("Nextcloud"), "La explicación dice cómo activarlo")
        let drive = client(.google).account
        XCTAssertNil(drive.versionsLimitation(for: item("x")))
        XCTAssertNotNil(drive.versionsLimitation(for: CloudFile(id: "d", name: "Docs", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true)))
        XCTAssertNotNil(drive.versionsLimitation(for: item("s", mime: "application/vnd.google-apps.shortcut")))
    }

    func testRestoringAndDeletingAreRefusedWhereTheyCannotWork() async throws {
        StubProtocol.handler = { request in XCTFail("No request expected: \(request.url!)"); return (500, [:], Data()) }
        let current = FileVersion(id: "c", modified: nil, size: 1, isCurrent: true), old = FileVersion(id: "o", modified: nil, size: 1)
        let doc = item("g", name: "Informe", mime: "application/vnd.google-apps.document")
        let drive = client(.google), box = client(.box), onedrive = client(.microsoft), dropbox = client(.dropbox)
        XCTAssertNotNil(drive.account.versionLimitation(.restore, version: current, of: item("f")), "La actual ya es la actual")
        XCTAssertNotNil(drive.account.versionLimitation(.restore, version: old, of: doc), "Un documento de Google solo se exporta")
        XCTAssertNil(drive.account.versionLimitation(.restore, version: old, of: item("f")))
        XCTAssertNotNil(drive.account.versionLimitation(.delete, version: old, of: doc))
        XCTAssertNotNil(box.account.versionLimitation(.delete, version: current, of: item("f")))
        XCTAssertNil(box.account.versionLimitation(.delete, version: old, of: item("f")))
        for api in [onedrive, dropbox] {
            XCTAssertNotNil(api.account.versionLimitation(.delete, version: old, of: item("f")))
            do { try await api.deleteVersion(old, of: item("f")); XCTFail("\(api.account.cloud)") } catch {}
        }
        do { try await drive.restoreVersion(old, of: doc); XCTFail("Google Docs") } catch {}
        do { try await box.restoreVersion(current, of: item("f")); XCTFail("Current") } catch {}
    }

    // MARK: - Versions handed to the download paths

    func testAVersionTravelsAsItsOwnItemWithASuffixedName() throws {
        let date = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 12, hour: 10, minute: 31)))
        let version = FileVersion(id: "r7", modified: date, size: 3, checksum: ContentHash(algorithm: .md5, value: abcMD5))
        let file = item("/docs/informe.pdf")
        let synthetic = VersionedFile.make(file, version: version)
        XCTAssertEqual(synthetic.name, "informe (versión 2026-09-12 10.31).pdf")
        XCTAssertNotEqual(synthetic.id, file.id, "No se confunde con el archivo actual, ni en las copias locales")
        XCTAssertEqual(synthetic.size, 3)
        XCTAssertEqual(synthetic.checksum, version.checksum, "Se verifica contra la suma de la versión")
        XCTAssertEqual(PreviewKind.forFile(synthetic), .pdf, "La vista previa sigue sabiendo qué es")
        XCTAssertNil(VersionedFile.reference(file))

        // A queued download is written to disk and read back after a restart: the version must survive that.
        let decoded = try JSONDecoder().decode(CloudFile.self, from: JSONEncoder().encode(synthetic))
        let reference = try XCTUnwrap(VersionedFile.reference(decoded))
        XCTAssertEqual(reference.file.id, "/docs/informe.pdf")
        XCTAssertEqual(reference.versionID, "r7")

        let doc = item("g", name: "Informe", mime: "application/vnd.google-apps.document")
        XCTAssertEqual(VersionedFile.make(doc, version: version).name, "Informe (versión 2026-09-12 10.31)", "La exportación añade la extensión")
    }

    // MARK: - Google Drive

    func testDriveListsRevisionsNewestFirstWithTheHeadAsCurrent() async throws {
        serve { _, request in
            if request.query["pageToken"] == nil {
                return (200, [:], Data(#"{"nextPageToken":"p2","revisions":[{"id":"1","modifiedTime":"2026-09-01T10:00:00.000Z","size":"3","md5Checksum":"aa","lastModifyingUser":{"displayName":"Ana"}}]}"#.utf8))
            }
            return (200, [:], Data(#"{"revisions":[{"id":"2","modifiedTime":"2026-09-12T10:31:00.000Z","size":"5","md5Checksum":"bb","keepForever":true,"lastModifyingUser":{"emailAddress":"luis@example.com"}}]}"#.utf8))
        }
        let versions = try await client(.google).versions(of: item("f1"))
        XCTAssertEqual(paths, ["GET /drive/v3/files/f1/revisions", "GET /drive/v3/files/f1/revisions"])
        XCTAssertTrue(seen[0].query["fields"]?.contains("md5Checksum") == true, seen[0].query["fields"] ?? "")
        XCTAssertEqual(seen[1].query["pageToken"], "p2")
        XCTAssertEqual(versions.map(\.id), ["2", "1"])
        XCTAssertEqual(versions.map(\.isCurrent), [true, false], "La última revisión de Drive es el contenido de hoy")
        XCTAssertEqual(versions[0].author, "luis@example.com")
        XCTAssertEqual(versions[1].author, "Ana")
        XCTAssertTrue(versions[0].keepForever)
        XCTAssertEqual(versions[1].size, 3)
        XCTAssertEqual(versions[1].checksum, ContentHash(algorithm: .md5, value: "aa"))
    }

    func testDriveDownloadsARevisionAndChecksItAgainstItsOwnChecksum() async throws {
        serve { [abc] _, request in
            XCTAssertEqual(request.path, "/drive/v3/files/f1/revisions/1")
            return (200, [:], abc)
        }
        let api = client(.google)
        let good = VersionedFile.make(item("f1"), version: FileVersion(id: "1", modified: nil, size: 3, checksum: ContentHash(algorithm: .md5, value: abcMD5)))
        let target = temporaryFile(); defer { try? FileManager.default.removeItem(at: target) }
        let verification = try await api.download(file: good, to: target)
        XCTAssertEqual(verification, .verified)
        XCTAssertEqual(seen.first?.query["alt"], "media")
        XCTAssertEqual(try Data(contentsOf: target), abc)

        seen = []
        let bad = VersionedFile.make(item("f1"), version: FileVersion(id: "1", modified: nil, size: 3, checksum: ContentHash(algorithm: .md5, value: "00000000000000000000000000000000")))
        let other = temporaryFile()
        do { _ = try await api.download(file: bad, to: other); XCTFail("La suma no coincide") }
        catch let error as DownloadIntegrityError { XCTAssertEqual(error, .checksumMismatch(name: bad.name)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path), "La copia dañada no se queda")
        XCTAssertEqual(paths, ["GET /drive/v3/files/f1/revisions/1"], "Una versión no cambia: no se pregunta por el archivo actual")
    }

    func testDriveExportsADocumentRevisionThroughItsOwnLinkOnly() async throws {
        serve { request, entry in
            if entry.host == "docs.google.com" { return (200, [:], Data("%PDF-1.4".utf8)) }
            XCTAssertEqual(entry.query["fields"], "exportLinks")
            return (200, [:], Data(#"{"exportLinks":{"application/pdf":"https://docs.google.com/feeds/download/documents/export/Export?id=g&revision=4&exportFormat=pdf"}}"#.utf8))
        }
        let doc = item("g", name: "Informe", mime: "application/vnd.google-apps.document")
        let target = temporaryFile(); defer { try? FileManager.default.removeItem(at: target) }
        let verification = try await client(.google).download(file: VersionedFile.make(doc, version: FileVersion(id: "4", modified: nil, size: nil)), to: target, exportMime: "application/pdf")
        XCTAssertEqual(verification, .exported)
        XCTAssertEqual(paths, ["GET /drive/v3/files/g/revisions/4", "GET /feeds/download/documents/export/Export"])
        XCTAssertEqual(seen[1].headers["Authorization"], "Bearer test-token")
        XCTAssertFalse(GoogleDriveProvider.googleExportHost(URL(string: "https://evil.example.com/export")!), "El token solo viaja a Google")
        XCTAssertFalse(GoogleDriveProvider.googleExportHost(URL(string: "http://docs.google.com/export")!))
    }

    func testDriveRestoresByUploadingTheRevisionOverTheFileAndDeletesByID() async throws {
        serve { [abc, abcMD5] _, request in
            switch request.method {
            case "GET": return (200, [:], abc)
            case "PATCH": return (200, ["Location": "https://www.googleapis.com/upload/session/9"], Data())
            case "PUT": return (200, [:], Data(#"{"id":"f1","md5Checksum":"\#(abcMD5)","size":"3"}"#.utf8))
            default: return (204, [:], Data())
            }
        }
        let api = client(.google)
        let version = FileVersion(id: "1", modified: nil, size: 3, checksum: ContentHash(algorithm: .md5, value: abcMD5))
        try await api.restoreVersion(version, of: item("f1"))
        XCTAssertEqual(paths, ["GET /drive/v3/files/f1/revisions/1", "PATCH /upload/drive/v3/files/f1", "PUT /upload/session/9"])
        XCTAssertEqual(seen[1].query["uploadType"], "resumable", "Sube encima del mismo archivo, no crea otro")
        XCTAssertEqual(seen[2].body, "abc")

        // Bytes that do not match the revision are never sent as the file's new content.
        seen = []
        let wrong = FileVersion(id: "1", modified: nil, size: 3, checksum: ContentHash(algorithm: .md5, value: "00000000000000000000000000000000"))
        do { try await api.restoreVersion(wrong, of: item("f1")); XCTFail("No debe subir") } catch {}
        XCTAssertEqual(paths, ["GET /drive/v3/files/f1/revisions/1"])

        seen = []
        try await api.deleteVersion(version, of: item("f1"))
        XCTAssertEqual(paths, ["DELETE /drive/v3/files/f1/revisions/1"])
    }

    // MARK: - OneDrive

    func testOneDriveListsReadsAndRestoresVersionsOnTheServer() async throws {
        serve { [abc] _, request in
            if request.path.hasSuffix("/versions") {
                return (200, [:], Data(#"{"value":[{"id":"3.0","lastModifiedDateTime":"2026-09-12T10:31:00Z","size":5,"lastModifiedBy":{"user":{"displayName":"Ana"}}},{"id":"2.0","lastModifiedDateTime":"2026-09-01T10:00:00Z","size":3}]}"#.utf8))
            }
            if request.path.hasSuffix("/content") { return (200, [:], abc) }
            return (204, [:], Data())
        }
        let api = client(.microsoft)
        let versions = try await api.versions(of: item("X"))
        XCTAssertEqual(versions.map(\.id), ["3.0", "2.0"])
        XCTAssertEqual(versions.map(\.isCurrent), [true, false])
        XCTAssertEqual(versions[0].author, "Ana")
        let target = temporaryFile(); defer { try? FileManager.default.removeItem(at: target) }
        let verification = try await api.download(file: VersionedFile.make(item("X"), version: versions[1]), to: target)
        XCTAssertEqual(verification, .unavailable, "Graph no da sumas de las versiones: solo se comprueba el tamaño")
        try await api.restoreVersion(versions[1], of: item("X"))
        XCTAssertEqual(paths, ["GET /v1.0/me/drive/items/X/versions", "GET /v1.0/me/drive/items/X/versions/2.0/content",
                               "POST /v1.0/me/drive/items/X/versions/2.0/restoreVersion"])
    }

    // MARK: - Dropbox

    func testDropboxListsRevisionsDownloadsByRevAndRestores() async throws {
        var hasher = DropboxContentHash(); hasher.update(abc)
        let hash = hasher.finalize()
        serve { [abc] _, request in
            if request.path == "/2/files/list_revisions" {
                return (200, [:], Data(#"{"is_deleted":false,"entries":[{"rev":"a2","server_modified":"2026-09-12T10:31:00Z","size":5,"content_hash":"x"},{"rev":"a1","server_modified":"2026-09-01T10:00:00Z","size":3,"content_hash":"\#(hash)"}]}"#.utf8))
            }
            if request.path == "/2/files/download" { return (200, [:], abc) }
            return (200, [:], Data("{}".utf8))
        }
        let api = client(.dropbox)
        let versions = try await api.versions(of: item("/docs/informe.pdf"))
        XCTAssertTrue(seen[0].body.contains(#""path":"\/docs\/informe.pdf""#) && seen[0].body.contains(#""mode":"path""#), seen[0].body)
        XCTAssertEqual(versions.map(\.id), ["a2", "a1"])
        XCTAssertEqual(versions.map(\.isCurrent), [true, false])
        let target = temporaryFile(); defer { try? FileManager.default.removeItem(at: target) }
        let verification = try await api.download(file: VersionedFile.make(item("/docs/informe.pdf"), version: versions[1]), to: target)
        XCTAssertEqual(verification, .verified)
        XCTAssertEqual(seen[1].headers["Dropbox-API-Arg"], #"{"path":"rev:a1"}"#)
        try await api.restoreVersion(versions[1], of: item("/docs/informe.pdf"))
        XCTAssertEqual(seen[2].path, "/2/files/restore")
        XCTAssertTrue(seen[2].body.contains(#""rev":"a1""#), seen[2].body)

        serve { _, _ in (200, [:], Data(#"{"is_deleted":true,"entries":[{"rev":"a1","server_modified":"2026-09-01T10:00:00Z","size":3}]}"#.utf8)) }
        let deleted = try await api.versions(of: item("/docs/borrado.pdf"))
        XCTAssertEqual(deleted.map(\.isCurrent), [false], "Un archivo borrado no tiene versión actual")
    }

    // MARK: - Box

    func testBoxPutsTheCurrentVersionFirstPromotesAndDeletes() async throws {
        serve { [abc] _, request in
            switch (request.method, request.path) {
            case ("GET", "/2.0/files/42"):
                return (200, [:], Data(#"{"id":"42","size":5,"modified_at":"2026-09-12T10:31:00Z","sha1":"cur","modified_by":{"name":"Ana"},"file_version":{"id":"v3","sha1":"cur"}}"#.utf8))
            case ("GET", "/2.0/files/42/versions"):
                return (200, [:], Data(#"{"total_count":2,"entries":[{"id":"v2","size":3,"modified_at":"2026-09-05T08:00:00Z","sha1":"\#(self.abcSHA1)","trashed_at":null,"modified_by":{"login":"luis@example.com"}},{"id":"v1","size":2,"modified_at":"2026-09-01T08:00:00Z","sha1":"s1","trashed_at":"2026-09-06T08:00:00Z"}]}"#.utf8))
            case ("GET", "/2.0/files/42/content"): return (200, [:], abc)
            case ("POST", _): return (201, [:], Data(#"{"type":"file_version","id":"v4"}"#.utf8))
            default: return (204, [:], Data())
            }
        }
        let api = client(.box)
        let versions = try await api.versions(of: item("42"))
        XCTAssertEqual(versions.map(\.id), ["v3", "v2"], "La versión en la papelera de Box no se ofrece")
        XCTAssertEqual(versions.map(\.isCurrent), [true, false])
        XCTAssertEqual(versions[0].author, "Ana")
        XCTAssertEqual(versions[1].author, "luis@example.com")
        let target = temporaryFile(); defer { try? FileManager.default.removeItem(at: target) }
        let verification = try await api.download(file: VersionedFile.make(item("42"), version: versions[1]), to: target)
        XCTAssertEqual(verification, .verified)
        XCTAssertEqual(seen[2].query["version"], "v2")
        try await api.restoreVersion(versions[1], of: item("42"))
        XCTAssertEqual(paths[3], "POST /2.0/files/42/versions/current")
        XCTAssertTrue(seen[3].body.contains(#""type":"file_version""#) && seen[3].body.contains(#""id":"v2""#), seen[3].body)
        try await api.deleteVersion(versions[1], of: item("42"))
        XCTAssertEqual(paths[4], "DELETE /2.0/files/42/versions/v2")

        serve { _, request in request.path.hasSuffix("/versions") ? (403, [:], Data(#"{"code":"access_denied_insufficient_permissions"}"#.utf8)) : (200, [:], Data(#"{"id":"42"}"#.utf8)) }
        do { _ = try await api.versions(of: item("42")); XCTFail("Cuenta gratuita") }
        catch { XCTAssertTrue(error.localizedDescription.contains("plan"), error.localizedDescription) }
    }

    // MARK: - Nextcloud

    private static let multistatus = #"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">"#
    private static let fileID = multistatus + #"<d:response><d:href>/remote.php/dav/files/ana/docs/informe.pdf</d:href><d:propstat><d:prop><oc:fileid>123</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#
    private static func versionList(_ prefix: String = "") -> String {
        multistatus
            + #"<d:response><d:href>\#(prefix)/remote.php/dav/versions/ana/versions/123/</d:href><d:propstat><d:prop><d:getcontenttype/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>"#
            + #"<d:response><d:href>\#(prefix)/remote.php/dav/versions/ana/versions/123/1757000000</d:href><d:propstat><d:prop><d:getcontentlength>3</d:getcontentlength><d:getlastmodified>Thu, 04 Sep 2025 15:33:20 GMT</d:getlastmodified><nc:version-author>luis</nc:version-author></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat><d:propstat><d:prop><nc:version-label/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>"#
            + #"<d:response><d:href>\#(prefix)/remote.php/dav/versions/ana/versions/123/1757600000</d:href><d:propstat><d:prop><d:getcontentlength>5</d:getcontentlength><d:getlastmodified>Thu, 11 Sep 2025 14:13:20 GMT</d:getlastmodified><nc:version-label>Entrega</nc:version-label></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>"#
            + "</d:multistatus>"
    }

    func testNextcloudFindsTheFileIDListsReadsRestoresAndDeletesVersions() async throws {
        serve { [abc] _, request in
            switch request.method {
            case "PROPFIND" where request.path.hasPrefix("/remote.php/dav/files/"): return (207, [:], Data(Self.fileID.utf8))
            case "PROPFIND": return (207, [:], Data(Self.versionList().utf8))
            case "GET": return (200, [:], abc)
            default: return (201, [:], Data())
            }
        }
        let api = client(.webdav, nextcloud: true)
        let file = item("/docs/informe.pdf", modified: Date(timeIntervalSince1970: 1_758_000_000))
        let versions = try await api.versions(of: file)
        XCTAssertEqual(paths, ["PROPFIND /remote.php/dav/files/ana/docs/informe.pdf", "PROPFIND /remote.php/dav/versions/ana/versions/123"])
        XCTAssertTrue(seen[0].body.contains("oc:fileid"), seen[0].body)
        XCTAssertEqual(seen[0].headers["Depth"], "0")
        XCTAssertEqual(seen[1].headers["Depth"], "1")
        XCTAssertEqual(versions.map(\.id), ["123/current", "123/1757600000", "123/1757000000"])
        XCTAssertEqual(versions.map(\.isCurrent), [true, false, false], "La lista de Nextcloud no trae la actual: es el propio archivo")
        XCTAssertEqual(versions[1].label, "Entrega")
        XCTAssertEqual(versions[2].author, "luis")
        XCTAssertEqual(versions[2].size, 3)
        XCTAssertEqual(versions[2].modified, Date(timeIntervalSince1970: 1_757_000_000))

        seen = []
        let target = temporaryFile(); defer { try? FileManager.default.removeItem(at: target) }
        _ = try await api.download(file: VersionedFile.make(file, version: versions[2]), to: target)
        try await api.restoreVersion(versions[2], of: file)
        try await api.deleteVersion(versions[1], of: file)
        XCTAssertEqual(paths, ["GET /remote.php/dav/versions/ana/versions/123/1757000000", "MOVE /remote.php/dav/versions/ana/versions/123/1757000000",
                               "DELETE /remote.php/dav/versions/ana/versions/123/1757600000"])
        XCTAssertEqual(seen[1].headers["Destination"], "https://nube.example.com/remote.php/dav/versions/ana/restore/target")
    }

    func testNextcloudOnTheLegacyAddressAsksWhoTheUserIs() async throws {
        serve { _, request in
            if request.path == "/nube/remote.php/dav/" {
                return (207, [:], Data((Self.multistatus + #"<d:response><d:href>/nube/remote.php/dav/</d:href><d:propstat><d:prop><d:current-user-principal><d:href>/nube/remote.php/dav/principals/users/ana/</d:href></d:current-user-principal></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#).utf8))
            }
            if request.path.hasPrefix("/nube/remote.php/webdav/") { return (207, [:], Data(Self.fileID.utf8)) }
            return (207, [:], Data(Self.versionList("/nube").utf8))
        }
        let versions = try await client(.webdav, server: "https://nube.example.com/nube/remote.php/webdav", nextcloud: true).versions(of: item("/docs/informe.pdf"))
        XCTAssertEqual(paths, ["PROPFIND /nube/remote.php/dav/", "PROPFIND /nube/remote.php/webdav/docs/informe.pdf", "PROPFIND /nube/remote.php/dav/versions/ana/versions/123"])
        XCTAssertTrue(seen[0].body.contains("current-user-principal"))
        XCTAssertEqual(versions.count, 3)
    }
}
