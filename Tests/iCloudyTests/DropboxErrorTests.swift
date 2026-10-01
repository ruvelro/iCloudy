import XCTest
@testable import iCloudy

/// Dropbox answers most refusals with a 409 whose body carries both `error_summary` and a tagged `error` object. The
/// shared parser used to read the object, find no message in it, and show "HTTP 409" for all of them.
@MainActor
final class DropboxErrorTests: XCTestCase {
    private var requests: [String] = []
    override func setUp() { requests = [] }
    override func tearDown() { StubProtocol.handler = nil }

    private func dropbox() -> CloudAPI {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let account = Account(id: "dbx", cloud: .dropbox, name: "Dropbox", email: "d@example.com", clientID: "client", clientSecret: nil)
        return CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "token" })
    }
    private func serve(_ answer: @escaping (String) -> (Int, [String: String], Data)) {
        StubProtocol.handler = { [self] request in
            let path = request.url!.path
            requests.append(path)
            return answer(path)
        }
    }
    private func refusal(_ summary: String, tag: String) -> Data {
        Data(#"{"error_summary":"\#(summary)","error":{".tag":"\#(tag)"}}"#.utf8)
    }
    private func failure(status: Int = 409, _ body: Data) -> ServiceError? {
        let response = HTTPURLResponse(url: URL(string: "https://api.dropboxapi.com/2/files/move_v2")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        do { try HTTP.validate(response, data: body); return nil } catch { return error as? ServiceError }
    }
    private func file(_ id: String) -> CloudFile {
        CloudFile(id: id, name: (id as NSString).lastPathComponent, mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
    }

    func testTheSummaryIsReadBeforeTheTaggedObject() throws {
        let error = try XCTUnwrap(failure(refusal("path/not_found/..", tag: "path")))
        XCTAssertEqual(error.code, "path/not_found/..", "El código conserva el resumen tal cual, para quien lo compare")
        XCTAssertFalse(error.localizedDescription.contains("409"), error.localizedDescription)
        XCTAssertTrue(error.localizedDescription.contains("no encuentra"), error.localizedDescription)
        // Other providers keep their nested error object.
        let drive = try XCTUnwrap(failure(status: 403, Data(#"{"error":{"code":"forbidden","message":"Sin permiso"}}"#.utf8)))
        XCTAssertEqual(drive.code, "forbidden"); XCTAssertEqual(drive.detail, "Sin permiso")
    }

    func testCommonSummariesBecomeClearSentences() throws {
        let cases: [(String, String)] = [
            ("path/not_found/...", "no encuentra"),
            ("to/conflict/file/..", "Ya hay un elemento"),
            ("path/insufficient_space/..", "No queda espacio"),
            ("path/malformed_path/..", "no acepta esa ruta"),
            ("path/disallowed_name/..", "no admite ese nombre"),
            ("too_many_write_operations/..", "demasiados cambios"),
        ]
        for (summary, expected) in cases {
            let error = try XCTUnwrap(failure(refusal(summary, tag: "path")))
            XCTAssertTrue(error.localizedDescription.contains(expected), "\(summary): \(error.localizedDescription)")
        }
        let unknown = try XCTUnwrap(failure(refusal("path/restricted_content/..", tag: "path")))
        XCTAssertTrue(unknown.localizedDescription.contains("path/restricted_content"), "Lo desconocido se muestra como lo escribió Dropbox")
    }

    func testLockContentionIsRetryableAndOtherRefusalsAreNot() throws {
        XCTAssertTrue(try XCTUnwrap(failure(refusal("path/too_many_write_operations/..", tag: "path"))).retryable)
        XCTAssertTrue(try XCTUnwrap(failure(status: 429, refusal("too_many_write_operations/..", tag: "too_many_write_operations"))).retryable)
        XCTAssertFalse(try XCTUnwrap(failure(refusal("path/conflict/folder/..", tag: "path"))).retryable)
        XCTAssertEqual(TransferQueue.outcome(for: try XCTUnwrap(failure(refusal("path/too_many_write_operations/..", tag: "path"))), attempts: 0, online: true), .retry)
    }

    func testARenameIntoAnExistingNameSaysSo() async throws {
        serve { [self] _ in (409, [:], refusal("to/conflict/file/..", tag: "to")) }
        do { try await dropbox().rename(file: file("/a.txt"), name: "b.txt"); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Ya hay un elemento"), error.localizedDescription) }
    }

    func testAWriteTurnedAwayForLockContentionIsSentAgain() async throws {
        var refused = false
        serve { [self] _ in
            if !refused { refused = true; return (429, ["Retry-After": "0"], refusal("too_many_write_operations/..", tag: "too_many_write_operations")) }
            return (200, [:], Data(#"{"metadata":{"name":"Nueva","path_lower":"/nueva",".tag":"folder"}}"#.utf8))
        }
        let id = try await dropbox().createFolder(name: "Nueva", parent: "root")
        XCTAssertEqual(id, "/nueva")
        XCTAssertEqual(requests, ["/2/files/create_folder_v2", "/2/files/create_folder_v2"])
    }

    func testAnOrdinaryRateLimitOnAWriteIsStillNotRepeated() async throws {
        serve { _ in (429, ["Retry-After": "0"], Data(#"{"error_summary":"too_many_requests/..","error":{".tag":"too_many_requests"}}"#.utf8)) }
        do { _ = try await dropbox().createFolder(name: "Nueva", parent: "root"); XCTFail("Debe fallar") } catch {}
        XCTAssertEqual(requests.count, 1, "Un 429 corriente no garantiza que la escritura no se aplicara")
    }

    func testLinkRefusalsStillReadTheSummaryThroughTheSharedParser() async throws {
        serve { [self] _ in (409, [:], refusal("shared_link_not_found/..", tag: "shared_link_not_found")) }
        let link = PublicLink(handle: "https://www.dropbox.com/s/x/a.pdf", file: file("/a.pdf"), url: URL(string: "https://www.dropbox.com/s/x/a.pdf")!,
                              access: .view, expires: nil, hasPassword: false, allowsDownload: nil, audience: nil, location: nil)
        do { try await dropbox().revokePublicLink(link); XCTFail("Debe fallar") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ya no existe"), error.localizedDescription) }
    }
}
