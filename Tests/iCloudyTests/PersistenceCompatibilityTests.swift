import XCTest
@testable import iCloudy

final class PersistenceCompatibilityTests: XCTestCase {
    func testExistingSharedAccountKeepsItsIdentityAndCredentialSource() throws {
        let fixture = Data(#"{"id":"google:123/drive:team","cloud":"google","name":"Team","email":"ana@example.com","clientID":"app","options":{"driveID":"team","credentialSource":"google:123"}}"#.utf8)
        let account = try JSONDecoder().decode(Account.self, from: fixture)
        XCTAssertEqual(account.driveID, "team")
        XCTAssertEqual(account.credentialKey, "google:123")
        XCTAssertNil(account.bookmark)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(account)) as? [String: Any])
        XCTAssertEqual(saved["cloud"] as? String, "google")
        XCTAssertEqual(saved["id"] as? String, "google:123/drive:team")
        XCTAssertEqual((saved["options"] as? [String: String])?["credentialSource"], "google:123")
    }

    func testPausedTransferKeepsItsRemoteCommitAndPendingRetirement() throws {
        let fixture = Data(#"{"accountID":"mega:ana@example.com","direction":"upload","localURL":"file:///tmp/source.bin","state":"paused","uploads":{"source.bin":{"total":10,"offset":10,"remoteID":"new-node","pendingRetirementID":"old-node","complete":false}}}"#.utf8)
        let transfer = try JSONDecoder().decode(Transfer.self, from: fixture)
        XCTAssertEqual(transfer.state, .paused)
        let checkpoint = try XCTUnwrap(transfer.uploads["source.bin"])
        XCTAssertEqual(checkpoint.remoteID, "new-node")
        XCTAssertEqual(checkpoint.pendingRetirementID, "old-node")
        XCTAssertFalse(checkpoint.complete)
        XCTAssertNil(checkpoint.integrity)
        XCTAssertEqual(transfer.parent, "root")
        let saved = try JSONDecoder().decode(Transfer.self, from: JSONEncoder().encode(transfer))
        XCTAssertEqual(saved.uploads["source.bin"]?.pendingRetirementID, "old-node")
    }
}
