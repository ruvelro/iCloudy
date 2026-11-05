import XCTest
@testable import iCloudy

final class PersistenceCompatibilityTests: XCTestCase {
    /// Up to 0.7 every mirror lived in one `mirrors.json`. Each moves into a file of its own, in the same order, and
    /// the old file stays beside itself, renamed, instead of being read again or deleted.
    @MainActor
    func testMirrorsOfTheSingleFileMoveIntoAFileEach() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = root.appendingPathComponent("mirrors.json")
        let fixture = Data(#"""
        [{"id":"8F9C2C51-4A8B-4E2E-9F7A-0D2B6C1E5A11","accountID":"google:1","remoteFolderID":"folder-b","remoteName":"ana / Fotos","localURL":"file:///tmp/Fotos/","mode":"twoWay","baseline":{"a.jpg":{"remoteID":"r1","remoteSize":3,"isFolder":false}},"paused":true},
         {"id":"0A1B2C3D-0000-4000-8000-000000000002","accountID":"dropbox:2","remoteFolderID":"folder-a","remoteName":"ana / Docs","localURL":"file:///tmp/Docs/"}]
        """#.utf8)
        try fixture.write(to: legacy)

        let manager = MirrorManager(storeURL: legacy)
        XCTAssertNil(manager.persistenceError)
        XCTAssertEqual(manager.mirrors.map(\.remoteFolderID), ["folder-b", "folder-a"])
        XCTAssertEqual(manager.mirrors[0].mode, .twoWay)
        XCTAssertTrue(manager.mirrors[0].paused)
        XCTAssertEqual(manager.mirrors[0].baseline["a.jpg"]?.remoteID, "r1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path), "El archivo único no se vuelve a leer")
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathExtension("migrated")), fixture, "Se conserva tal cual")
        let files = try FileManager.default.contentsOfDirectory(atPath: manager.directory.path).sorted()
        XCTAssertEqual(files, ["0A1B2C3D-0000-4000-8000-000000000002.json", "8F9C2C51-4A8B-4E2E-9F7A-0D2B6C1E5A11.json", "index.json"])

        // The next launch reads the folder, in the order of the list, not the order of the file names.
        let again = MirrorManager(storeURL: legacy)
        XCTAssertEqual(again.mirrors.map(\.remoteFolderID), ["folder-b", "folder-a"])
        again.setPaused(false, for: again.mirrors[0].id)
        StoreWriter.shared.flush()
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: manager.directory
            .appendingPathComponent("8F9C2C51-4A8B-4E2E-9F7A-0D2B6C1E5A11.json"))) as? [String: Any]
        XCTAssertEqual(written?["schemaVersion"] as? Int, 1)
        XCTAssertEqual((written?["items"] as? [String: Any])?["paused"] as? Bool, false, "Solo se reescribe ese reflejo")
    }

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
