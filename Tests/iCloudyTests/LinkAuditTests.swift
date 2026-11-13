import XCTest
@testable import iCloudy

/// The daily look over public links: which ones deserve a mention, and that the look itself never fails loudly.
@MainActor
final class LinkAuditTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func link(_ id: String, expires: TimeInterval? = nil, password: Bool = false, audience: String? = nil, inherited: Bool = false) -> PublicLink {
        let file = CloudFile(id: id, name: id + ".pdf", mime: "application/pdf", size: 1, modified: nil, webURL: nil, isFolder: false)
        var link = PublicLink(handle: "h" + id, file: file, url: URL(string: "https://example.com/" + id))
        link.expires = expires.map { now.addingTimeInterval($0) }; link.hasPassword = password; link.audience = audience; link.isInherited = inherited
        return link
    }

    func testEachLinkIsJudgedByItsDateItsPasswordAndWhoCanOpenIt() {
        let day: TimeInterval = 86_400
        XCTAssertEqual(LinkAudit.concern(of: link("a", expires: -1), now: now), .expired)
        XCTAssertEqual(LinkAudit.concern(of: link("b", expires: 3 * day), now: now), .expiringSoon)
        XCTAssertEqual(LinkAudit.concern(of: link("c", expires: 7 * day), now: now), .expiringSoon, "A week, to the second")
        XCTAssertNil(LinkAudit.concern(of: link("d", expires: 8 * day), now: now))
        XCTAssertEqual(LinkAudit.concern(of: link("e"), now: now), .openForever)
        XCTAssertNil(LinkAudit.concern(of: link("f", password: true), now: now), "A password is a limit of its own")
        XCTAssertNil(LinkAudit.concern(of: link("g", audience: "Empresa"), now: now), "Open to a company is not open to anyone")
        XCTAssertNil(LinkAudit.concern(of: link("h", inherited: true), now: now), "Judged on the folder it comes from")
        XCTAssertNil(LinkAudit.concern(of: link("i"), now: now, includingOpen: false))
        XCTAssertEqual(LinkAudit.concern(of: link("j", expires: 2 * day, password: true), now: now), .expiringSoon, "A password does not stop it expiring")
    }

    func testFindingsComeSortedByUrgency() {
        let day: TimeInterval = 86_400
        let found = LinkAudit.findings([link("abierto"), link("caducado", expires: -day), link("pasado", expires: 5 * day), link("mañana", expires: day), link("lejano", expires: 90 * day)],
                                       accountID: "a", now: now)
        XCTAssertEqual(found.map(\.link.file.id), ["mañana", "pasado", "abierto", "caducado"])
    }

    private func auditor(_ answers: [String: Result<[PublicLink], Error>], enabled: Bool = true, open: Bool = true) -> (LinkAuditor, [Account]) {
        let defaults = UserDefaults(suiteName: "links-" + UUID().uuidString)!
        defaults.set(enabled, forKey: Prefs.linkAudit); defaults.set(open, forKey: Prefs.linkAuditOpen)
        let accounts = [Account(id: "drive", cloud: .google, name: "Drive", email: "a@example.com", clientID: "c", clientSecret: nil),
                        Account(id: "box", cloud: .box, name: "Box", email: "b@example.com", clientID: "c", clientSecret: nil),
                        Account(id: "dropbox", cloud: .dropbox, name: "Dropbox", email: "c@example.com", clientID: "c", clientSecret: nil)]
        let auditor = LinkAuditor()
        auditor.defaults = defaults
        auditor.accounts = { accounts }
        auditor.client = { account in
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
            return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "token" })
        }
        // Drive lists links as a file search and Dropbox as list_shared_links; the stub answers each in its shape.
        StubProtocol.handler = { request in
            let host = request.url?.host ?? ""
            let key = host.contains("google") ? "drive" : "dropbox"
            switch answers[key] {
            case .failure?: return (403, [:], Data(#"{"error":{"code":403,"message":"Sin permiso"}}"#.utf8))
            default:
                if key == "drive" { return (200, [:], Data(#"{"files":[{"id":"f1","name":"informe.pdf","mimeType":"application/pdf","permissions":[{"id":"anyoneWithLink","type":"anyone","role":"reader"}]}]}"#.utf8)) }
                return (200, [:], Data(#"{"links":[],"has_more":false}"#.utf8))
            }
        }
        return (auditor, accounts)
    }

    func testOnlyAccountsThatCanListTheirLinksAreAskedAndOneFailingDoesNotHideTheOthers() async {
        struct Boom: Error {}
        let (auditor, _) = auditor(["dropbox": .failure(Boom())])
        await auditor.refresh()
        XCTAssertNotNil(auditor.lastChecked)
        XCTAssertEqual(auditor.failures.keys.sorted(), ["dropbox"], "Box has no list to ask for, so it is neither asked nor failed")
        XCTAssertEqual(auditor.findings.map(\.accountID), ["drive"])
        XCTAssertEqual(auditor.findings.first?.concern, .openForever)
        XCTAssertEqual(auditor.summary, "1 enlace público que revisar")
    }

    func testSwitchedOffItFindsNothingAndOpenLinksCanBeLeftOut() async {
        let (off, _) = auditor([:], enabled: false)
        await off.refresh()
        XCTAssertTrue(off.findings.isEmpty); XCTAssertNil(off.summary); XCTAssertNil(off.lastChecked)
        let (quiet, _) = auditor([:], open: false)
        await quiet.refresh()
        XCTAssertTrue(quiet.findings.isEmpty, "The only link there is an open one, and those were not asked about")
    }

    func testARevokedLinkLeavesTheListAtOnce() async {
        let (auditor, _) = auditor([:])
        await auditor.refresh()
        let finding = try! XCTUnwrap(auditor.findings.first)
        auditor.forget(finding)
        XCTAssertTrue(auditor.findings.isEmpty)
    }
}
