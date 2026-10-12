import XCTest
@testable import iCloudy

/// What each cloud lacked: pCloud versions and links, the Nextcloud and OneDrive bins, S3 temporary keys, profiles
/// and versions, and the key material of SFTP accounts.
@MainActor
final class CloudGapsTests: XCTestCase {
    private func client(_ cloud: Cloud, server: String? = nil, flavor: String? = nil, credentials: CredentialStore? = nil, id: String = "gap") -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        var options: [String: String] = cloud == .pcloud ? ["apiHost": "eapi.pcloud.com"] : [:]
        if let flavor { options["flavor"] = flavor }
        let account = Account(id: id, cloud: cloud, name: "Prueba", email: "ana@example.com", clientID: "client", clientSecret: nil,
                              serverURL: server, bookmark: nil, options: options)
        if let credentials { return CloudAPI(account: account, session: URLSession(configuration: config), credentials: credentials) }
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "test-token" })
    }
    private func file(_ id: String, _ name: String, folder: Bool = false, size: Int64? = 10) -> CloudFile {
        CloudFile(id: id, name: name, mime: folder ? "application/vnd.google-apps.folder" : "application/octet-stream", size: folder ? nil : size,
                  modified: Date(timeIntervalSince1970: 1_700_000_000), webURL: nil, isFolder: folder)
    }
    private func query(_ request: URLRequest) -> [String: String] {
        var values: [String: String] = [:]
        for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { values[item.name] = item.value ?? "" }
        for pair in requestBody(request).split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map { String($0).removingPercentEncoding ?? String($0) }
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    // MARK: - pCloud

    func testPCloudListsReadsAndRevertsRevisions() async throws {
        var calls: [(String, [String: String])] = []
        StubProtocol.handler = { request in
            let method = request.url!.lastPathComponent, values = self.query(request)
            calls.append((method, values))
            switch method {
            case "listrevisions":
                return (200, [:], Data(#"{"result":0,"metadata":{"id":"f9","name":"a.txt","size":30,"modified":1700000300},"revisions":[{"revisionid":11,"size":10,"created":1700000100},{"revisionid":12,"size":20,"created":1700000200}]}"#.utf8))
            case "getfilelink":
                return (200, [:], Data(#"{"result":0,"hosts":["c1.pcloud.com"],"path":"/x/a.txt"}"#.utf8))
            default:
                return (200, [:], Data(#"{"result":0}"#.utf8))
            }
        }
        let api = client(.pcloud)
        let target = file("f9", "a.txt")
        let versions = try await api.provider.versions(of: target)
        XCTAssertEqual(versions.map(\.id), ["current", "12", "11"], "La actual arriba, las demás de la más nueva a la más vieja")
        XCTAssertTrue(versions[0].isCurrent)
        _ = try await api.provider.versionContentRequest(for: target, version: "12", exportMime: nil)
        XCTAssertEqual(calls.last?.1["revisionid"], "12")
        _ = try await api.provider.versionContentRequest(for: target, version: "current", exportMime: nil)
        XCTAssertNil(calls.last?.1["revisionid"], "La actual se lee sin revisión")
        try await api.provider.restoreVersion(versions[2], of: target)
        XCTAssertEqual(calls.last?.0, "revertrevision")
        XCTAssertEqual(calls.last?.1["revisionid"], "11")
        XCTAssertTrue(Cloud.pcloud.capabilities.versions)
        XCTAssertFalse(Cloud.pcloud.capabilities.deletesVersions, "pCloud no borra revisiones sueltas")
    }

    func testPCloudLinksAreListedPerItemAndRevokedByTheirID() async throws {
        var deleted: String?
        StubProtocol.handler = { request in
            switch request.url!.lastPathComponent {
            case "listpublinks":
                return (200, [:], Data(#"{"result":0,"publinks":[{"linkid":5,"link":"https://u.pcloud.link/a","metadata":{"id":"f9","name":"a.txt","isfolder":false}},{"linkid":6,"link":"https://u.pcloud.link/b","metadata":{"id":"d3","name":"Fotos","isfolder":true}}]}"#.utf8))
            case "deletepublink":
                deleted = self.query(request)["linkid"]
                return (200, [:], Data(#"{"result":0}"#.utf8))
            default: return (500, [:], Data())
            }
        }
        let api = client(.pcloud)
        let links = try await api.provider.publicLinks(for: file("f9", "a.txt"))
        XCTAssertEqual(links.map(\.handle), ["5"])
        let all = try await api.provider.allPublicLinks()
        XCTAssertEqual(all.count, 2)
        try await api.provider.revokePublicLink(links[0])
        XCTAssertEqual(deleted, "5")
        XCTAssertTrue(Cloud.pcloud.capabilities.links.manage)
        XCTAssertTrue(Cloud.pcloud.capabilities.links.inventory)
    }

    // MARK: - Nextcloud's bin

    private let nextcloud = "https://nube.example.com/remote.php/dav/files/ana/Trabajo"

    func testNextcloudListsItsBinAndRestoresAndPurgesFromIt() async throws {
        var seen: [(String, String, String?)] = []
        StubProtocol.handler = { request in
            seen.append((request.httpMethod ?? "", request.url!.path, request.value(forHTTPHeaderField: "Destination")))
            if request.httpMethod == "PROPFIND" {
                return (207, [:], Data("""
                <?xml version="1.0"?><d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
                <d:response><d:href>/remote.php/dav/trashbin/ana/trash/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                <d:response><d:href>/remote.php/dav/trashbin/ana/trash/acta.pdf.d1700000000</d:href><d:propstat><d:prop>
                <nc:trashbin-filename>acta.pdf</nc:trashbin-filename><nc:trashbin-original-location>Trabajo/acta.pdf</nc:trashbin-original-location>
                <nc:trashbin-deletion-time>1700000000</nc:trashbin-deletion-time><d:getcontentlength>42</d:getcontentlength><d:getcontenttype>application/pdf</d:getcontenttype>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                <d:response><d:href>/remote.php/dav/trashbin/ana/trash/Viejo.d1700000001/</d:href><d:propstat><d:prop>
                <nc:trashbin-filename>Viejo</nc:trashbin-filename><d:getcontenttype>httpd/unix-directory</d:getcontenttype><d:resourcetype><d:collection/></d:resourcetype>
                </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
                </d:multistatus>
                """.utf8))
            }
            return (204, [:], Data())
        }
        let api = client(.webdav, server: nextcloud, flavor: "nextcloud")
        let binned = try await api.list(parent: Collection.trash.rootID)
        XCTAssertEqual(binned.map(\.name), ["Viejo", "acta.pdf"])
        let acta = try XCTUnwrap(binned.first { $0.name == "acta.pdf" })
        XCTAssertEqual(acta.id, "trash:/acta.pdf.d1700000000")
        XCTAssertEqual(acta.size, 42)
        XCTAssertEqual(acta.modified, Date(timeIntervalSince1970: 1_700_000_000), "La fecha es la del borrado")
        XCTAssertTrue(binned.first { $0.name == "Viejo" }?.isFolder == true)

        try await api.restore(file: acta)
        XCTAssertEqual(seen.last?.0, "MOVE")
        XCTAssertEqual(seen.last?.1, "/remote.php/dav/trashbin/ana/trash/acta.pdf.d1700000000")
        XCTAssertEqual(seen.last?.2, "https://nube.example.com/remote.php/dav/trashbin/ana/restore/acta.pdf.d1700000000")
        try await api.deletePermanently(file: acta)
        XCTAssertEqual(seen.last?.0, "DELETE")
        XCTAssertEqual(seen.last?.1, "/remote.php/dav/trashbin/ana/trash/acta.pdf.d1700000000")
        try await api.emptyTrash()
        XCTAssertEqual(seen.last?.1, "/remote.php/dav/trashbin/ana/trash")
        let trail = try await api.provider.folderTrail(id: "trash:/Viejo.d1700000001")
        XCTAssertEqual(trail.map(\.name), ["Viejo"])
    }

    func testOnlyNextcloudAccountsGetABinAndPlainWebDAVStillSaysItHasNone() async throws {
        let plain = Account(id: "w", cloud: .webdav, name: "", email: "", clientID: "", clientSecret: nil)
        var cloud = plain; cloud.options["flavor"] = "nextcloud"
        XCTAssertFalse(plain.capabilities.trashListing)
        XCTAssertFalse(plain.capabilities.reversibleTrash)
        XCTAssertTrue(cloud.capabilities.trashListing)
        XCTAssertTrue(cloud.capabilities.reversibleTrash)
        XCTAssertTrue(cloud.capabilities.emptyTrash)
        StubProtocol.handler = { _ in XCTFail("Nada que pedir"); return (500, [:], Data()) }
        do { _ = try await client(.webdav, server: nextcloud).list(parent: Collection.trash.rootID); XCTFail("Sin papelera") }
        catch { XCTAssertTrue(error.localizedDescription.contains("papelera"), error.localizedDescription) }
    }

    func testTheOriginalLocationCountsTheSubfolderTheAccountOpensAt() throws {
        let provider = client(.webdav, server: nextcloud, flavor: "nextcloud").provider as! WebDAVProvider
        XCTAssertEqual(try provider.nextcloudOriginalLocation("/acta.pdf"), "Trabajo/acta.pdf")
        XCTAssertEqual(try provider.nextcloudOriginalLocation("/Sub/b.txt"), "Trabajo/Sub/b.txt")
        let legacy = client(.webdav, server: "https://nube.example.com/remote.php/webdav", flavor: "nextcloud").provider as! WebDAVProvider
        XCTAssertEqual(try legacy.nextcloudOriginalLocation("/a.txt"), "a.txt")
    }

    // MARK: - OneDrive's bin

    func testOneDriveListsWhatICloudyBinnedAndRestoresItByID() async throws {
        let journal = OneDriveBinJournal(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json"))
        let accountID = "onedrive-" + UUID().uuidString
        journal.record(file("A1", "a.txt"), accountID: accountID, now: Date())
        journal.record(file("B2", "viejo.txt"), accountID: accountID, now: Date().addingTimeInterval(-31 * 86_400))
        XCTAssertEqual(journal.items(accountID: accountID).map(\.file.id), ["A1"], "Lo de hace más de 30 días ya no está en la papelera")

        // The shared journal is what the provider uses; the test cleans up after itself.
        defer { OneDriveBinJournal.shared.forgetAccount(accountID) }
        var seen: [String] = []
        StubProtocol.handler = { request in
            seen.append((request.httpMethod ?? "") + " " + request.url!.path)
            if request.url!.path.hasSuffix("/GONE/restore") { return (404, [:], Data(#"{"error":{"code":"itemNotFound"}}"#.utf8)) }
            return (request.httpMethod == "DELETE" ? 204 : 200, [:], Data("{}".utf8))
        }
        let api = client(.microsoft, id: accountID)
        try await api.trash(file: file("A1", "a.txt"))
        try await api.trash(file: file("GONE", "b.txt"))
        let listed = try await api.list(parent: Collection.trash.rootID)
        XCTAssertEqual(Set(listed.map(\.id)), ["A1", "GONE"])
        try await api.restore(file: file("A1", "a.txt"))
        XCTAssertEqual(seen.last, "POST /v1.0/me/drive/items/A1/restore")
        do { try await api.restore(file: file("GONE", "b.txt")); XCTFail("Ya no está") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ya no está"), error.localizedDescription) }
        let after = try await api.list(parent: Collection.trash.rootID)
        XCTAssertTrue(after.isEmpty, "Restaurado o desaparecido, deja de listarse")

        var library = Account(id: "lib", cloud: .microsoft, name: "", email: "", clientID: "", clientSecret: nil)
        library.options["driveID"] = "b!xyz"
        XCTAssertFalse(library.capabilities.trashListing, "Una biblioteca de SharePoint no tiene esta papelera")
    }

    // MARK: - S3

    private final class Keys: CredentialStore {
        var credential: Credential
        init(_ credential: Credential) { self.credential = credential }
        func read(_ key: String) throws -> Credential? { credential }
        func save(_ credential: Credential, key: String) throws { self.credential = credential }
    }
    private func s3(_ credential: Credential) -> CloudAPI {
        let account = S3Authentication.account(.aws, endpoint: URLComponents(string: "https://s3.eu-west-1.amazonaws.com")!, region: "eu-west-1",
                                               bucket: "fotos", addressing: .path, accessKey: credential.accessToken)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        return CloudAPI(account: account, session: URLSession(configuration: config), credentials: Keys(credential))
    }

    func testTemporaryKeysSendTheirTokenSignedAndExpireWhenTheySay() async throws {
        var request: URLRequest?
        StubProtocol.handler = { request = $0; return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>".utf8)) }
        let temporary = Credential(accessToken: "ASIA123", refreshToken: "", expires: Date().addingTimeInterval(3600), secret: "secreto", sessionToken: "TOKEN+/=")
        _ = try await s3(temporary).list(parent: "root")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "x-amz-security-token"), "TOKEN+/=")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "Authorization")?.contains("x-amz-security-token") == true, "El token va firmado")

        let link = try (s3(temporary).provider as! S3Provider).temporaryLink(for: file("fotos/a.jpg", "a.jpg"), lifetime: 60)
        XCTAssertTrue(link.query?.contains("X-Amz-Security-Token=TOKEN%2B%2F%3D") == true, link.absoluteString)

        let expired = Credential(accessToken: "ASIA123", refreshToken: "", expires: Date().addingTimeInterval(-1), secret: "secreto", sessionToken: "T")
        do { _ = try await s3(expired).list(parent: "root"); XCTFail("Caducadas") }
        catch { XCTAssertTrue(error.localizedDescription.contains("caducado"), error.localizedDescription) }

        StubProtocol.handler = { _ in (400, [:], Data("<Error><Code>ExpiredToken</Code><Message>The provided token has expired.</Message></Error>".utf8)) }
        let api = s3(temporary)
        do { _ = try await api.list(parent: "root"); XCTFail("El servidor dice que caducó") }
        catch { XCTAssertTrue(api.sessionExpired, "Hay que volver a conectarla") }
    }

    func testAWSProfilesAreReadFromEitherFile() {
        let profiles = AWSProfiles.parse("""
        # comentario
        [default]
        aws_access_key_id = AKIA1
        aws_secret_access_key = s1
        region = eu-west-1

        [profile trabajo]
        aws_access_key_id=ASIA2
        aws_secret_access_key=s2
        aws_session_token=t2
        aws_session_expiration = 2030-01-01T00:00:00Z

        [sso]
        sso_start_url = https://example.awsapps.com/start

        [trabajo]
        region = us-east-1
        """)
        XCTAssertEqual(profiles.map(\.name), ["default", "trabajo", "sso"])
        XCTAssertEqual(profiles[0].region, "eu-west-1")
        XCTAssertEqual(profiles[1].sessionToken, "t2")
        XCTAssertEqual(profiles[1].region, "us-east-1", "El mismo perfil en los dos ficheros se une")
        XCTAssertNotNil(profiles[1].expires)
        XCTAssertFalse(profiles[2].hasKeys)
        XCTAssertNotNil(profiles[2].indirection)
        var form = S3SignIn(service: .aws, region: "eu-west-3")
        form.adopt(profiles[1])
        XCTAssertEqual(form.accessKey, "ASIA2"); XCTAssertEqual(form.sessionToken, "t2"); XCTAssertEqual(form.region, "us-east-1")
    }

    func testS3VersionsAreListedReadRestoredAndDeleted() async throws {
        var requests: [URLRequest] = []
        StubProtocol.handler = { request in
            requests.append(request)
            if request.url?.query?.contains("versions") == true {
                return (200, [:], Data("""
                <ListVersionsResult><IsTruncated>false</IsTruncated>
                <Version><Key>a.jpg</Key><VersionId>v2</VersionId><IsLatest>true</IsLatest><LastModified>2026-01-02T00:00:00.000Z</LastModified><ETag>"0123456789abcdef0123456789abcdef"</ETag><Size>20</Size></Version>
                <Version><Key>a.jpg</Key><VersionId>v1</VersionId><IsLatest>false</IsLatest><LastModified>2026-01-01T00:00:00.000Z</LastModified><ETag>"x-2"</ETag><Size>10</Size></Version>
                <DeleteMarker><Key>a.jpg</Key><VersionId>dm</VersionId></DeleteMarker>
                <Version><Key>a.jpg.bak</Key><VersionId>other</VersionId><IsLatest>true</IsLatest><Size>1</Size></Version>
                </ListVersionsResult>
                """.utf8))
            }
            return (200, [:], Data("<CopyObjectResult><ETag>\"e\"</ETag></CopyObjectResult>".utf8))
        }
        let api = s3(Credential(accessToken: "AKIA", refreshToken: "", expires: .distantFuture, secret: "s"))
        let target = file("fotos/a.jpg", "a.jpg")
        let versions = try await api.provider.versions(of: target)
        XCTAssertEqual(versions.map(\.id), ["v2", "v1"], "Ni marcas de borrado ni otras claves con el mismo prefijo")
        XCTAssertTrue(versions[0].isCurrent)
        XCTAssertEqual(versions[0].checksum?.value, "0123456789abcdef0123456789abcdef")
        XCTAssertNil(versions[1].checksum, "Un ETag multiparte no es un MD5")

        let read = try await api.provider.versionContentRequest(for: target, version: "v1", exportMime: nil)
        XCTAssertTrue(read.url?.query?.contains("versionId=v1") == true)
        try await api.provider.restoreVersion(versions[1], of: target)
        XCTAssertEqual(requests.last?.httpMethod, "PUT")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "x-amz-copy-source"), "/fotos/a.jpg?versionId=v1")
        try await api.provider.deleteVersion(versions[1], of: target)
        XCTAssertEqual(requests.last?.httpMethod, "DELETE")
        XCTAssertTrue(requests.last?.url?.query?.contains("versionId=v1") == true)
    }

    func testABucketWithoutVersioningSaysHowToGetSome() async throws {
        StubProtocol.handler = { _ in
            (200, [:], Data("<ListVersionsResult><Version><Key>a.jpg</Key><VersionId>null</VersionId><IsLatest>true</IsLatest><Size>3</Size></Version></ListVersionsResult>".utf8))
        }
        let api = s3(Credential(accessToken: "AKIA", refreshToken: "", expires: .distantFuture, secret: "s"))
        do { _ = try await api.provider.versions(of: file("fotos/a.jpg", "a.jpg")); XCTFail("Sin historial") }
        catch { XCTAssertTrue(error.localizedDescription.contains("control de versiones"), error.localizedDescription) }
    }

    // MARK: - SFTP key material

    func testSFTPKeyMaterialTravelsInTheCredentialSecret() {
        let material = SFTPKeyMaterial(key: "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----", passphrase: "frase")
        XCTAssertEqual(SFTPKeyMaterial.decode(material.encoded), material)
        XCTAssertNil(SFTPKeyMaterial.decode(""), "Una cuenta con contraseña no lleva clave")
        let credential = Credential(accessToken: "dTpw", refreshToken: "", expires: .distantFuture, secret: material.encoded)
        let decoded = try? JSONDecoder().decode(Credential.self, from: JSONEncoder().encode(credential))
        XCTAssertEqual(decoded.flatMap { SFTPKeyMaterial.decode($0.secret) }, material)
    }
}
