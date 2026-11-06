import XCTest
@testable import iCloudy

/// Digest authentication against the RFCs' own examples, and the WebDAV provider answering Digest challenges and
/// sending bearer tokens over the HTTP stub.
@MainActor
final class WebDAVAuthTests: XCTestCase {
    private let server = "https://nas.example.com/dav"

    func testDigestResponsesMatchTheRFCExamples() throws {
        // RFC 2617, section 3.5.
        let legacy = HTTPDigest.Challenge(realm: "testrealm@host.com", nonce: "dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque: nil,
                                          algorithm: .md5, qopAuth: true, stale: false)
        XCTAssertEqual(HTTPDigest.response(challenge: legacy, user: "Mufasa", password: "Circle Of Life", method: "GET",
                                           uri: "/dir/index.html", count: 1, clientNonce: "0a4f113b"), "6629fae49393a05397450978507c4ef1")
        // RFC 7616, section 3.9.1, with both algorithms the example gives.
        for (algorithm, expected) in [(HTTPDigest.Algorithm.sha256, "753927fa0e85d155564e2e272a28d1802ca10daf4496794697cf8db5856cb6c1"),
                                      (.md5, "8ca523f5e9506fed4657c9700eebdbec")] {
            let challenge = HTTPDigest.Challenge(realm: "http-auth@example.org", nonce: "7ypf/xlj9XXwfDPEoM4URrv/xwf94BcCAzFZH4GiTo0v",
                                                 opaque: "FQhe/qaU925kfnzjCev0ciny7QMkPqMAFRtzCUYo5tdS", algorithm: algorithm, qopAuth: true, stale: false)
            XCTAssertEqual(HTTPDigest.response(challenge: challenge, user: "Mufasa", password: "Circle of Life", method: "GET", uri: "/dir/index.html",
                                               count: 1, clientNonce: "f2/wE4q74E6zIJEtWaHKaf5wv/H5QzzpXusqGemxURZJ"), expected, algorithm.rawValue)
        }
    }

    func testTheStrongestOfSeveralChallengesIsChosen() throws {
        let header = #"Digest realm="http-auth@example.org", qop="auth, auth-int", algorithm=SHA-256, nonce="7ypf/x", opaque="FQ", Digest realm="http-auth@example.org", qop="auth, auth-int", algorithm=MD5, nonce="7ypf/x", opaque="FQ", Basic realm="x""#
        let response = HTTPURLResponse(url: URL(string: server)!, statusCode: 401, httpVersion: nil, headerFields: ["WWW-Authenticate": header])!
        let challenge = try XCTUnwrap(HTTPDigest.challenge(in: response))
        XCTAssertEqual(challenge.algorithm, .sha256)
        XCTAssertEqual(challenge.opaque, "FQ")
        XCTAssertTrue(challenge.qopAuth)
        let parsed = HTTPDigest.challenges(header)
        XCTAssertEqual(parsed.map(\.scheme), ["digest", "digest", "basic"])
        XCTAssertEqual(parsed[0].parameters["qop"], "auth, auth-int", "A quoted value keeps its commas")
        let onlyIntegrity = HTTPURLResponse(url: URL(string: server)!, statusCode: 401, httpVersion: nil,
                                            headerFields: ["WWW-Authenticate": #"Digest realm="r", nonce="n", qop="auth-int""#])!
        XCTAssertNil(HTTPDigest.challenge(in: onlyIntegrity), "auth-int alone cannot be answered")
    }

    /// A server that wants Digest: no credentials gets the challenge, a correct response gets the listing.
    private func digestServer(seen: Box<[String?]>) -> StubProtocol.Handler {
        let challenge = HTTPDigest.Challenge(realm: "nas", nonce: "n0nce", opaque: "op", algorithm: .md5, qopAuth: true, stale: false)
        return { request in
            let header = request.value(forHTTPHeaderField: "Authorization")
            seen.value.append(header)
            let refusal: (Int, [String: String], Data) = (401, ["WWW-Authenticate": #"Digest realm="nas", nonce="n0nce", opaque="op", qop="auth", algorithm=MD5"#], Data())
            guard let header, header.hasPrefix("Digest ") else { return refusal }
            let fields = Dictionary(uniqueKeysWithValues: HTTPDigest.challenges(header)[0].parameters.map { ($0.key, $0.value) })
            let expected = HTTPDigest.response(challenge: challenge, user: "ana", password: "secreto", method: request.httpMethod ?? "",
                                               uri: fields["uri"] ?? "", count: UInt32(fields["nc"] ?? "", radix: 16) ?? 0, clientNonce: fields["cnonce"] ?? "")
            XCTAssertEqual(fields["uri"], HTTPDigest.requestTarget(request.url!), "The hashed URI is the request target")
            guard fields["response"] == expected, fields["opaque"] == "op" else { return refusal }
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"><d:response><d:href>/dav/</d:href><d:propstat><d:prop><d:resourcetype><d:collection/></d:resourcetype></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response><d:response><d:href>/dav/a%20b.txt</d:href><d:propstat><d:prop><d:resourcetype/></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>"#.utf8))
        }
    }
    private func credentials() -> MemoryCredentials {
        let store = MemoryCredentials()
        store.stored["nas"] = Credential(accessToken: Data("ana:secreto".utf8).base64EncodedString(), refreshToken: "", expires: .distantFuture)
        return store
    }

    func testADigestAccountNeverSendsItsPasswordAndAnswersEveryRequest() async throws {
        let seen = Box<[String?]>([])
        StubProtocol.handler = digestServer(seen: seen)
        let api = makeStubbedClient(stubbedAccount(.webdav, id: "nas", server: server, options: ["auth": "digest"]), credentials: credentials())
        let first = try await api.list(parent: "root")
        XCTAssertEqual(first.map(\.name), ["a b.txt"])
        _ = try await api.list(parent: "root")
        XCTAssertNil(seen.value.first ?? "x", "The challenge is fetched with no credentials at all")
        XCTAssertFalse(seen.value.contains { $0?.hasPrefix("Basic") == true }, "A Digest account never sends Basic")
        XCTAssertEqual(seen.value.count, 3, "One challenge, then each request answered directly")
        XCTAssertFalse(api.sessionExpired)
    }

    func testABasicAccountFollowsAServerThatSwitchedToDigest() async throws {
        let seen = Box<[String?]>([])
        StubProtocol.handler = digestServer(seen: seen)
        let api = makeStubbedClient(stubbedAccount(.webdav, id: "nas", server: server), credentials: credentials())
        _ = try await api.list(parent: "root")
        _ = try await api.list(parent: "root")
        XCTAssertEqual(seen.value.map { $0?.split(separator: " ").first.map(String.init) }, ["Basic", "Digest", "Digest"],
                       "One refusal, then Digest from the start")
    }

    func testWrongDigestCredentialsExpireTheSessionAndATokenAccountExplainsDigest() async throws {
        StubProtocol.handler = { _ in (401, ["WWW-Authenticate": #"Digest realm="nas", nonce="n", qop="auth""#], Data()) }
        let wrong = makeStubbedClient(stubbedAccount(.webdav, id: "nas", server: server, options: ["auth": "digest"]), credentials: credentials())
        do { _ = try await wrong.list(parent: "root"); XCTFail("Refused twice") } catch {}
        XCTAssertTrue(wrong.sessionExpired, "A refused Digest response means the password is wrong")

        let token = MemoryCredentials()
        token.stored["tok"] = Credential(accessToken: "abc", refreshToken: "", expires: .distantFuture)
        let bearer = makeStubbedClient(stubbedAccount(.webdav, id: "tok", server: server, options: ["auth": "bearer"]), credentials: token)
        do { _ = try await bearer.list(parent: "root"); XCTFail("A token cannot answer Digest") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Digest"), error.localizedDescription) }
        XCTAssertFalse(bearer.sessionExpired)
    }

    func testABearerAccountSendsItsToken() async throws {
        var header: String?
        StubProtocol.handler = { request in
            header = request.value(forHTTPHeaderField: "Authorization")
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>"#.utf8))
        }
        let token = MemoryCredentials()
        token.stored["tok"] = Credential(accessToken: "eyJ.token", refreshToken: "", expires: .distantFuture)
        _ = try await makeStubbedClient(stubbedAccount(.webdav, id: "tok", server: server, options: ["auth": "bearer"]), credentials: token).list(parent: "root")
        XCTAssertEqual(header, "Bearer eyJ.token")
    }

    func testSignInDetectsDigestAndAcceptsATokenWithoutUser() async throws {
        let seen = Box<[String?]>([])
        StubProtocol.handler = digestServer(seen: seen)
        let (account, credential) = try await WebDAVAuthentication(session: stubbedSession())
            .signInWebDAV(server: server, username: "ana", password: "secreto")
        XCTAssertEqual(account.webdavAuth, .digest, "The account remembers that the server wants Digest")
        XCTAssertEqual(credential.accessToken, Data("ana:secreto".utf8).base64EncodedString())

        var header: String?
        StubProtocol.handler = { request in
            header = request.value(forHTTPHeaderField: "Authorization")
            return (207, [:], Data(#"<?xml version="1.0"?><d:multistatus xmlns:d="DAV:"/>"#.utf8))
        }
        let (tokenAccount, tokenCredential) = try await WebDAVAuthentication(session: stubbedSession())
            .signInWebDAV(server: "https://ocis.example.com/remote.php/webdav", username: "", password: "Bearer eyJ.abc", auth: .bearer)
        XCTAssertEqual(header, "Bearer eyJ.abc")
        XCTAssertEqual(tokenAccount.webdavAuth, .bearer)
        XCTAssertEqual(tokenCredential.accessToken, "eyJ.abc", "The token is stored as it is, without the scheme")
        XCTAssertTrue(tokenAccount.id.hasSuffix("#token"))
    }
}
