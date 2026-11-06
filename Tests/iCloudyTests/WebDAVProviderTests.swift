import XCTest
import CryptoKit
@testable import iCloudy

/// WebDAV and Nextcloud over the HTTP stub: PROPFIND parsing, verbs, sign-in and credentials.
@MainActor
final class WebDAVProviderTests: XCTestCase {
    private func client(_ cloud: Cloud, server: String? = nil) -> CloudAPI {
        makeStubbedClient(cloud, server: server ?? (cloud == .webdav ? "https://dav.example.com/remote.php/dav/files/ana" : nil))
    }
    private func temporaryFile(_ payload: Data) throws -> URL {
        let url = try temporaryRoot().appendingPathComponent("payload")
        try payload.write(to: url)
        return url
    }

    func testWebDAVParsesMultistatusAndSkipsTheFolderItself() throws {
        let xml = Data("""
        <?xml version="1.0"?>
        <d:multistatus xmlns:d="DAV:">
          <d:response><d:href>/remote.php/dav/files/ana/Fotos/</d:href>
            <d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/ana/Fotos/ni%C3%B1o.jpg</d:href>
            <d:propstat><d:prop><d:displayname>niño.jpg</d:displayname><d:getcontentlength>2048</d:getcontentlength>
            <d:getlastmodified>Mon, 12 Jan 2026 10:00:00 GMT</d:getlastmodified><d:getcontenttype>image/jpeg</d:getcontenttype>
            <d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
            <d:propstat><d:prop><d:quota-used-bytes/></d:prop><d:status>HTTP/1.1 404 Not Found</d:status></d:propstat></d:response>
          <d:response><d:href>/remote.php/dav/files/ana/Fotos/Viaje/</d:href>
            <d:propstat><d:prop><d:displayname>Viaje</d:displayname><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let entries = WebDAVEntry.parse(xml, basePath: "/remote.php/dav/files/ana")
        XCTAssertEqual(entries.map(\.path), ["/Fotos", "/Fotos/niño.jpg", "/Fotos/Viaje"], "Hrefs are percent-decoded and made relative")
        let photo = entries[1].file
        XCTAssertEqual(photo.name, "niño.jpg")
        XCTAssertEqual(photo.size, 2048)
        XCTAssertEqual(photo.mime, "image/jpeg")
        XCTAssertFalse(photo.isFolder)
        XCTAssertEqual(photo.modified, Date(timeIntervalSince1970: 1_768_212_000))
        XCTAssertTrue(entries[2].file.isFolder)
        XCTAssertNil(entries[1].quotaUsed, "A 404 propstat must not leak into the item")
    }

    func testWebDAVListFiltersTheRequestedFolderAndBuildsEncodedURLs() async throws {
        var url: URL?
        var depth = ""
        StubProtocol.handler = { request in
            url = request.url; depth = request.value(forHTTPHeaderField: "Depth") ?? ""
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            return (207, [:], Data("""
            <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
            <d:response><d:href>/remote.php/dav/files/ana/Fotos</d:href><d:propstat><d:prop>
            <d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            <d:response><d:href>/remote.php/dav/files/ana/Fotos/a.txt</d:href><d:propstat><d:prop>
            <d:displayname>a.txt</d:displayname><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
            </d:multistatus>
            """.utf8))
        }
        let files = try await client(.webdav).list(parent: "/Fotos")
        XCTAssertEqual(depth, "1")
        XCTAssertEqual(url?.path, "/remote.php/dav/files/ana/Fotos")
        XCTAssertEqual(files.map(\.name), ["a.txt"], "The folder itself is not one of its own children")
    }

    func testWebDAVMoveAndDeleteUseTheRightVerbsAndHeaders() async throws {
        var seen: [(String, String?)] = []
        StubProtocol.handler = { request in
            seen.append((request.httpMethod ?? "", request.value(forHTTPHeaderField: "Destination")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic test-token", "WebDAV authenticates with Basic")
            return (204, [:], Data())
        }
        let api = client(.webdav)
        let file = CloudFile(id: "/Fotos/niño.jpg", name: "niño.jpg", mime: "image/jpeg", size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.move(file: file, to: "/Destino")
        XCTAssertEqual(seen.last?.0, "MOVE")
        XCTAssertEqual(seen.last?.1, "https://dav.example.com/remote.php/dav/files/ana/Destino/ni%C3%B1o.jpg")
        try await api.copy(file: file, to: "/Destino")
        XCTAssertEqual(seen.last?.0, "COPY")
        try await api.rename(file: file, name: "gato.jpg")
        XCTAssertEqual(seen.last?.1, "https://dav.example.com/remote.php/dav/files/ana/Fotos/gato.jpg", "Renaming keeps the parent")
        try await api.trash(file: file)
        XCTAssertEqual(seen.last?.0, "DELETE")
        XCTAssertEqual((api.provider as! WebDAVProvider).webdavTrail(id: "/uno/dos").map(\.id), ["/uno", "/uno/dos"])
    }

    func testWebDAVRejectsPublicLinksInsteadOfPretending() async throws {
        let api = client(.webdav)
        let file = CloudFile(id: "/a.txt", name: "a.txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        StubProtocol.handler = { _ in XCTFail("Unsupported features must not reach the network"); return (500, [:], Data()) }
        do { _ = try await api.publicLink(for: file); XCTFail("Expected an explicit refusal") }
        catch { XCTAssertTrue(error.localizedDescription.contains("enlaces públicos"), error.localizedDescription) }
    }

    func testAWebPageIsNotAListingHoweverPoliteItsStatusIs() async throws {
        // A misread address, or a proxy, answers a PROPFIND with the site's own page and a 200. Reading that as an
        // empty folder left the account showing nothing for ever, with no error to explain it.
        StubProtocol.handler = { _ in (200, [:], Data("<!doctype html><html><body>Nextcloud</body></html>".utf8)) }
        do {
            _ = try await client(.webdav).list(parent: "root")
            XCTFail("Una página web no es un listado")
        } catch { XCTAssertTrue(error.localizedDescription.contains("no es un listado"), error.localizedDescription) }

        // An empty 207, which is what an empty folder really looks like, stays empty and does not complain.
        StubProtocol.handler = { _ in (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8)) }
        let empty = try await client(.webdav).list(parent: "root")
        XCTAssertTrue(empty.isEmpty)
    }

    func testMovingUsesTheNameOnTheServerNotTheOneItLikesToDisplay() async throws {
        // `displayname` is what the server would like shown, and some report it with different capitalisation or a
        // title of their own. Building the destination from it renamed the item as a side effect of moving it.
        XCTAssertEqual(WebDAVProvider.webdavName("/Fotos/niño.JPG"), "niño.JPG")
        XCTAssertEqual(WebDAVProvider.webdavName("/"), "/")
        var destinations: [String?] = []
        StubProtocol.handler = { request in
            destinations.append(request.value(forHTTPHeaderField: "Destination"))
            return (204, [:], Data())
        }
        let api = client(.webdav)
        let file = CloudFile(id: "/Fotos/IMG_0001.JPG", name: "Un título cualquiera", mime: "image/jpeg",
                             size: 1, modified: nil, webURL: nil, isFolder: false)
        try await api.move(file: file, to: "/Destino")
        XCTAssertEqual(destinations.last, "https://dav.example.com/remote.php/dav/files/ana/Destino/IMG_0001.JPG")
        try await api.copy(file: file, to: "/Destino")
        XCTAssertEqual(destinations.last, "https://dav.example.com/remote.php/dav/files/ana/Destino/IMG_0001.JPG")
    }

    func testAnHrefThatDiffersOnlyInCapitalisationStillLosesItsPrefix() {
        // Reverse proxies routinely echo the base with different capitalisation. Leaving it in made every id carry
        // the prefix twice once it was turned back into a URL.
        let xml = Data("""
        <?xml version="1.0"?><d:multistatus xmlns:d="DAV:">
        <d:response><d:href>/Remote.php/DAV/files/ana/Fotos/a.txt</d:href><d:propstat><d:prop>
        <d:displayname>a.txt</d:displayname><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>
        """.utf8)
        let entries = WebDAVEntry.parse(xml, basePath: "/remote.php/dav/files/ana")
        XCTAssertEqual(entries.map(\.path), ["/Fotos/a.txt"])
    }

    func testADigestChallengeIsNotAWrongPassword() async throws {
        // An account signed in with a token cannot answer Digest (a password one does: WebDAVAuthTests). Calling the
        // challenge an expired session sent people to re-type credentials that were right all along.
        StubProtocol.handler = { _ in (401, ["WWW-Authenticate": "Digest realm=\"nas\", nonce=\"abc\""], Data()) }
        let api = makeStubbedClient(.webdav, server: "https://dav.example.com/remote.php/dav/files/ana", options: ["auth": "bearer"])
        do { _ = try await api.list(parent: "root"); XCTFail("Debe explicar qué pasa") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Digest"), error.localizedDescription) }
        XCTAssertFalse(api.sessionExpired, "No es una sesión caducada")
    }

    func testNextcloudReusesTheLinkAnItemAlreadyHasAndRepeatsWhatTheServerSays() async throws {
        let account = Account(id: "webdav:nc", cloud: .webdav, name: "NC", email: "ana@nc", clientID: "", clientSecret: nil,
                              serverURL: "https://nube.ejemplo.com/remote.php/dav/files/ana", bookmark: nil,
                              options: ["flavor": "nextcloud"])
        let api = makeStubbedClient(account, token: "token")
        let file = CloudFile(id: "/nota.txt", name: "nota.txt", mime: "text/plain", size: 4, modified: nil, webURL: nil, isFolder: false)

        // Nextcloud makes a new link every time it is asked, and each has to be revoked separately.
        var methods: [String] = []
        StubProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            return (200, [:], Data(#"{"ocs":{"meta":{"status":"ok"},"data":[{"share_type":0,"url":"https://nube/persona"},{"share_type":3,"url":"https://nube/s/yaexiste"}]}}"#.utf8))
        }
        let reused = try await api.publicLink(for: file)
        XCTAssertEqual(reused.absoluteString, "https://nube/s/yaexiste", "Se reutiliza el enlace público que ya tenía")
        XCTAssertEqual(methods, ["GET"], "Sin crear un segundo enlace")

        // With none to reuse, one is created.
        methods = []
        StubProtocol.handler = { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "GET" { return (200, [:], Data(#"{"ocs":{"meta":{"status":"ok"},"data":[]}}"#.utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "OCS-APIRequest"), "true")
            return (200, [:], Data(#"{"ocs":{"meta":{"status":"ok"},"data":{"url":"https://nube/s/nuevo"}}}"#.utf8))
        }
        let created = try await api.publicLink(for: file)
        XCTAssertEqual(created.absoluteString, "https://nube/s/nuevo")
        XCTAssertEqual(methods, ["GET", "POST"])

        // And a refusal keeps the server's own words instead of a bare HTTP code.
        StubProtocol.handler = { request in
            if request.httpMethod == "GET" { return (200, [:], Data(#"{"ocs":{"meta":{"status":"ok"},"data":[]}}"#.utf8)) }
            return (403, [:], Data(#"{"ocs":{"meta":{"status":"failure","statuscode":403,"message":"Se exige contraseña en los enlaces públicos"}}}"#.utf8))
        }
        do { _ = try await api.publicLink(for: file); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Se exige contraseña"), error.localizedDescription) }
    }

    func testAPasswordInTheClearIsOnlyAllowedWhereItCannotLeaveTheBuilding() async throws {
        // A Basic password travels in every request. macOS blocks plain HTTP off the local network anyway, and over
        // the internet it would be handing the password to whoever is listening.
        for local in ["nas.local", "192.168.1.10", "10.0.0.5", "172.16.3.1", "127.0.0.1", "localhost", "diskstation"] {
            XCTAssertTrue(LoginAddress.isLocalNetwork(local), local)
        }
        for remote in ["nube.ejemplo.com", "8.8.8.8", "172.32.0.1", "11.0.0.1"] {
            XCTAssertFalse(LoginAddress.isLocalNetwork(remote), remote)
        }
        // An IPv6 literal has no dots either, and a NAS reachable over native IPv6 is as public as any other server.
        XCTAssertFalse(LoginAddress.isLocalNetwork("2606:4700::1111"), "Una dirección IPv6 pública no es la red local")
        XCTAssertFalse(LoginAddress.isLocalNetwork("[2606:4700::1111]"))
        XCTAssertTrue(LoginAddress.isLocalNetwork("::1"))
        XCTAssertTrue(LoginAddress.isLocalNetwork("fe80::1"), "Enlace local")
        XCTAssertTrue(LoginAddress.isLocalNetwork("fd00::1"), "Rango privado de IPv6")
        let config = StubProtocol.configuration()
        let oauth = WebDAVAuthentication(session: URLSession(configuration: config))
        StubProtocol.handler = { _ in (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8)) }
        let nas = try await oauth.signInWebDAV(server: "http://nas.local/dav", username: "ana", password: "secreta")
        XCTAssertEqual(nas.0.serverURL, "http://nas.local/dav", "En la red local se permite")
        StubProtocol.handler = { _ in XCTFail("No debe contactarse"); return (500, [:], Data()) }
        do {
            _ = try await oauth.signInWebDAV(server: "http://nube.ejemplo.com/dav", username: "ana", password: "secreta")
            XCTFail("Fuera de la red local no")
        } catch { XCTAssertTrue(error.localizedDescription.contains("cifrado"), error.localizedDescription) }
    }

    func testCredentialsDoNotFollowARedirectToSomewhereElse() async throws {
        // The Authorization header is set by hand, and URLSession carries a hand-set header across redirects without
        // asking. A server answering with a 302 elsewhere would be handed the account's Basic password.
        let guardian = RedirectGuard.shared
        let session = URLSession(configuration: .ephemeral)
        let original = URLRequest(url: URL(string: "https://dav.example.com/dav/a.txt")!)
        let task = session.dataTask(with: original)
        defer { task.cancel() }
        let answer = HTTPURLResponse(url: original.url!, statusCode: 302, httpVersion: nil, headerFields: nil)!

        var elsewhere = URLRequest(url: URL(string: "https://otro.example.com/dav/a.txt")!)
        elsewhere.setValue("Basic secreto", forHTTPHeaderField: "Authorization")
        elsewhere.setValue("s=1", forHTTPHeaderField: "Cookie")
        let crossed = await guardian.urlSession(session, task: task, willPerformHTTPRedirection: answer, newRequest: elsewhere)
        XCTAssertNil(crossed?.value(forHTTPHeaderField: "Authorization"), "La contraseña no viaja a otro servidor")
        XCTAssertNil(crossed?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(crossed?.url?.host, "otro.example.com", "Pero la redirección se sigue")

        var sameHost = URLRequest(url: URL(string: "https://dav.example.com/otra/ruta")!)
        sameHost.setValue("Basic secreto", forHTTPHeaderField: "Authorization")
        let kept = await guardian.urlSession(session, task: task, willPerformHTTPRedirection: answer, newRequest: sameHost)
        XCTAssertEqual(kept?.value(forHTTPHeaderField: "Authorization"), "Basic secreto", "Dentro del mismo servidor es normal")
    }

    func testConfigurationValidatesEachProviderAndRefusesWebDAV() throws {
        let config = OAuthConfiguration(googleClientID: "1234567890-example.apps.googleusercontent.com", googleDesktopClientSecret: "g",
                                        microsoftClientID: "12345678-1234-1234-1234-123456789012",
                                        dropboxAppKey: "abcdefghij1234", boxClientID: String(repeating: "b", count: 32), boxClientSecret: "s")
        XCTAssertEqual(try config.client(for: .dropbox).secret, "", "Dropbox desktop apps use PKCE without a secret")
        XCTAssertEqual(try config.client(for: .box).secret, "s")
        XCTAssertThrowsError(try config.client(for: .webdav)) { XCTAssertTrue($0.localizedDescription.contains("WebDAV")) }
        XCTAssertThrowsError(try OAuthConfiguration(dropboxAppKey: "corto").client(for: .dropbox))
        // A plist written before these providers existed must still load.
        let legacy = Data(#"<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>googleClientID</key><string>x</string><key>googleDesktopClientSecret</key><string>y</string><key>microsoftClientID</key><string>z</string></dict></plist>"#.utf8)
        let decoded = try PropertyListDecoder().decode(OAuthConfiguration.self, from: legacy)
        XCTAssertEqual(decoded.googleClientID, "x")
        XCTAssertEqual(decoded.dropboxAppKey, "")
    }

    func testWebDAVSignInValidatesTheServerBeforeStoringAnything() async throws {
        let config = StubProtocol.configuration()
        let oauth = WebDAVAuthentication(session: URLSession(configuration: config))
        StubProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "PROPFIND")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("ana:secreta".utf8).base64EncodedString())
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8))
        }
        let (account, credential) = try await oauth.signInWebDAV(server: "dav.example.com/remote.php/dav/files/ana/", username: "ana", password: "secreta")
        XCTAssertEqual(account.cloud, .webdav)
        XCTAssertEqual(account.serverURL, "https://dav.example.com/remote.php/dav/files/ana", "Scheme added and trailing slash removed")
        XCTAssertEqual(account.id, "webdav:dav.example.com/remote.php/dav/files/ana#ana")
        XCTAssertEqual(credential.accessToken, Data("ana:secreta".utf8).base64EncodedString())
        XCTAssertGreaterThan(credential.expires, Date(timeIntervalSinceNow: 86_400), "Basic credentials do not expire on their own")

        StubProtocol.handler = { _ in (401, [:], Data()) }
        do { _ = try await oauth.signInWebDAV(server: "https://dav.example.com", username: "ana", password: "mala"); XCTFail("Expected a rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rechazó"), error.localizedDescription) }
        StubProtocol.handler = { _ in XCTFail("A malformed address must not be contacted"); return (500, [:], Data()) }
        do { _ = try await oauth.signInWebDAV(server: "no es una url", username: "a", password: "b"); XCTFail("Expected a rejection") }
        catch { XCTAssertTrue(error.localizedDescription.contains("dirección"), error.localizedDescription) }
    }

    func testCredentialsTypedIntoTheWebDAVAddressAreUsedButNeverStored() async throws {
        // Password managers hand out `https://ana:secreta@nas/dav`. The address lives in accounts.json, outside the
        // Keychain, so what rides in it is stripped and treated as the credentials it is.
        let config = StubProtocol.configuration()
        let oauth = WebDAVAuthentication(session: URLSession(configuration: config))
        var authorization: String?
        StubProtocol.handler = { request in
            authorization = request.value(forHTTPHeaderField: "Authorization")
            XCTAssertNil(request.url?.user, "The request itself carries no userinfo either")
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8))
        }
        let (account, credential) = try await oauth.signInWebDAV(server: "https://ana:secr%40ta@dav.example.com/dav/", username: "", password: "")
        XCTAssertEqual(account.serverURL, "https://dav.example.com/dav")
        XCTAssertEqual(account.id, "webdav:dav.example.com/dav#ana")
        XCTAssertEqual(credential.accessToken, Data("ana:secr@ta".utf8).base64EncodedString(), "Percent-decoded, as typed")
        XCTAssertEqual(authorization, "Basic " + Data("ana:secr@ta".utf8).base64EncodedString())

        // What the form says wins over what the address carries.
        let (typed, typedCredential) = try await oauth.signInWebDAV(server: "https://otra:x@dav.example.com/dav", username: "ana", password: "secreta")
        XCTAssertEqual(typed.serverURL, "https://dav.example.com/dav")
        XCTAssertEqual(typedCredential.accessToken, Data("ana:secreta".utf8).base64EncodedString())
    }

    private func webdavSignIn() -> WebDAVAuthentication {
        let config = StubProtocol.configuration()
        StubProtocol.handler = { _ in (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"></d:multistatus>"#.utf8)) }
        return WebDAVAuthentication(session: URLSession(configuration: config))
    }

    func testWebDAVServersThatDifferOnlyInPortOrSchemeAreDifferentAccounts() async throws {
        // The id used to be host + path + user, so a NAS with two WebDAV services on different ports, or the same
        // path over http and https, overwrote each other's credential and everything else keyed by the id.
        let oauth = webdavSignIn()
        var accounts: [Account] = []
        for server in ["https://nas.local/dav", "https://nas.local:5006/dav", "http://nas.local/dav", "http://nas.local:5005/dav"] {
            let (account, _) = try await oauth.signInWebDAV(server: server, username: "ana", password: "secreta", existing: accounts)
            accounts.append(account)
        }
        XCTAssertEqual(accounts.map(\.id), ["webdav:nas.local/dav#ana", "webdav:https://nas.local:5006/dav#ana",
                                            "webdav:http://nas.local/dav#ana", "webdav:http://nas.local:5005/dav#ana"])
        // The default port written out, a capitalised host or a trailing slash are still the same server.
        for same in ["https://nas.local:443/dav", "https://NAS.local/dav/", "nas.local/dav"] {
            let (again, _) = try await oauth.signInWebDAV(server: same, username: "ana", password: "secreta", existing: accounts)
            XCTAssertEqual(again.id, "webdav:nas.local/dav#ana", same)
        }
        let (http80, _) = try await oauth.signInWebDAV(server: "http://nas.local:80/dav", username: "ana", password: "secreta", existing: accounts)
        XCTAssertEqual(http80.id, "webdav:http://nas.local/dav#ana")
        // Another user, or another path, on the same origin is another account; the path keeps its case.
        let (other, _) = try await oauth.signInWebDAV(server: "https://nas.local:5006/dav", username: "luis", password: "x", existing: accounts)
        XCTAssertEqual(other.id, "webdav:https://nas.local:5006/dav#luis")
        let (path, _) = try await oauth.signInWebDAV(server: "https://nas.local/DAV", username: "ana", password: "x", existing: accounts)
        XCTAssertEqual(path.id, "webdav:nas.local/DAV#ana")
        let (ipv6, _) = try await oauth.signInWebDAV(server: "http://[fe80::1]:8080/dav", username: "ana", password: "x")
        XCTAssertEqual(ipv6.id, "webdav:http://[fe80::1]:8080/dav#ana", "Los dos puntos de IPv6 no se confunden con el puerto")
    }

    func testStoredWebDAVAccountsKeepTheirIDsWhenSignedInAgain() async throws {
        // Accounts written by earlier versions, with ids from the old rule. Their Keychain entries, favourites,
        // mirrors, transfers, caches and Spotlight entries are keyed by these exact strings.
        let stored = Data(#"""
        [{"id":"webdav:dav.example.com/remote.php/dav/files/ana#ana","cloud":"webdav","name":"dav.example.com","email":"ana@dav.example.com","clientID":"","serverURL":"https://dav.example.com/remote.php/dav/files/ana"},
         {"id":"webdav:nas.local/dav#ana","cloud":"webdav","name":"nas.local","email":"ana@nas.local","clientID":"","serverURL":"http://nas.local:8080/dav"},
         {"id":"webdav:Box.Example.com/dav#ana","cloud":"webdav","name":"Box.Example.com","email":"ana@Box.Example.com","clientID":"","serverURL":"https://Box.Example.com/dav"}]
        """#.utf8)
        let accounts = try JSONDecoder().decode([Account].self, from: stored)
        let oauth = webdavSignIn()

        // https on the default port: the id is the old one byte for byte, even with no account to match.
        let (fresh, _) = try await oauth.signInWebDAV(server: "https://dav.example.com/remote.php/dav/files/ana", username: "ana", password: "s")
        XCTAssertEqual(fresh.id, "webdav:dav.example.com/remote.php/dav/files/ana#ana")
        let (common, _) = try await oauth.signInWebDAV(server: "https://dav.example.com/remote.php/dav/files/ana/", username: "ana", password: "s", existing: accounts)
        XCTAssertEqual(common.id, accounts[0].id)

        // An old account on a non-default port has an id without the port. Reconnecting to it, as the login form does
        // with its stored address, finds it again instead of creating a second account next to it.
        let (ported, _) = try await oauth.signInWebDAV(server: "http://nas.local:8080/dav", username: "ana", password: "s", existing: accounts)
        XCTAssertEqual(ported.id, "webdav:nas.local/dav#ana")
        // A capitalised host from before the host was lowercased is found again too.
        let (cased, _) = try await oauth.signInWebDAV(server: "https://box.example.com/dav", username: "ana", password: "s", existing: accounts)
        XCTAssertEqual(cased.id, "webdav:Box.Example.com/dav#ana")

        // That old id now belongs to http on 8080. The https default-port server on the same host and path must not
        // overwrite it, so it takes the spelled-out form, and keeps it when it signs in again.
        let (https, _) = try await oauth.signInWebDAV(server: "https://nas.local/dav", username: "ana", password: "s", existing: accounts)
        XCTAssertEqual(https.id, "webdav:https://nas.local/dav#ana")
        let (again, _) = try await oauth.signInWebDAV(server: "https://nas.local/dav", username: "ana", password: "s", existing: accounts + [https])
        XCTAssertEqual(again.id, https.id)
        // Another user on that old account's origin is not that account.
        let (luis, _) = try await oauth.signInWebDAV(server: "http://nas.local:8080/dav", username: "luis", password: "s", existing: accounts)
        XCTAssertEqual(luis.id, "webdav:http://nas.local:8080/dav#luis")
    }
}
