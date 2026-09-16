import XCTest
@testable import iCloudy

@MainActor
final class LocalCopyTests: XCTestCase {
    private func file(_ name: String, id: String, modified: Date? = nil, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: name, mime: folder ? "application/vnd.google-apps.folder" : "text/plain",
                  size: 10, modified: modified, webURL: nil, isFolder: folder)
    }
    private func makeIndex() throws -> (LocalCopyIndex, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LocalCopyIndex(storeURL: root.appendingPathComponent("copies.json")), root)
    }
    private func copy(_ id: String, path: URL, remoteModified: Date?) -> LocalCopy {
        LocalCopy(accountID: "google:1", fileID: id, name: path.lastPathComponent, path: path.path, bookmark: nil,
                  size: 10, remoteModified: remoteModified, savedAt: Date(), origin: .download)
    }

    func testStatusTellsCloudOnlyFromDownloadedAndOutdated() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let saved = Date(timeIntervalSince1970: 1_000_000)
        let local = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: local)
        index.record(copy("f1", path: local, remoteModified: saved))

        XCTAssertEqual(index.status(for: file("b.txt", id: "f2"), accountID: "google:1"), .cloudOnly)
        XCTAssertEqual(index.status(for: file("a.txt", id: "f1"), accountID: "otra"), .cloudOnly, "Ids are scoped per account")
        guard case .downloaded = index.status(for: file("a.txt", id: "f1", modified: saved), accountID: "google:1") else {
            return XCTFail("An unchanged remote file must read as downloaded")
        }
        guard case .outdated(let stale) = index.status(for: file("a.txt", id: "f1", modified: saved.addingTimeInterval(60)), accountID: "google:1") else {
            return XCTFail("A newer remote version must read as outdated")
        }
        XCTAssertEqual(stale.path, local.path)
        // A remote file whose date is unknown cannot be declared stale.
        guard case .downloaded = index.status(for: file("a.txt", id: "f1", modified: nil), accountID: "google:1") else {
            return XCTFail("Without a remote date the copy stays valid")
        }
    }

    func testFoldersAreNeverMarkedAsDownloaded() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        index.record(copy("d1", path: root.appendingPathComponent("Carpeta"), remoteModified: nil))
        XCTAssertEqual(index.status(for: file("Carpeta", id: "d1", folder: true), accountID: "google:1"), .cloudOnly,
                       "iCloudy cannot claim that everything inside a folder is present and current")
    }

    func testRecordingPersistsAndForgettingNeverDeletesTheFile() throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let local = root.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: local)
        index.record(copy("f1", path: local, remoteModified: nil))
        index.record(LocalCopy(accountID: "microsoft:2", fileID: "f9", name: "b", path: local.path, bookmark: nil, size: 3, remoteModified: nil, savedAt: Date(), origin: .upload))
        XCTAssertEqual(index.totalBytes, 13)

        let restored = LocalCopyIndex(storeURL: index.storeURL)
        XCTAssertEqual(restored.copies.count, 2, "Survives a restart")
        restored.removeAccount("google:1")
        XCTAssertEqual(restored.copies.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path), "Forgetting a copy must never delete it")
        restored.clear()
        XCTAssertTrue(restored.copies.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: local.path))
        XCTAssertTrue(LocalCopyIndex(storeURL: index.storeURL).copies.isEmpty)
    }

    func testVerifyPrunesCopiesTheUserMovedOrDeleted() async throws {
        let (index, root) = try makeIndex()
        defer { try? FileManager.default.removeItem(at: root) }
        let present = root.appendingPathComponent("aqui.txt")
        try Data("x".utf8).write(to: present)
        let gone = root.appendingPathComponent("borrado.txt")
        index.record(copy("f1", path: present, remoteModified: nil))
        index.record(copy("f2", path: gone, remoteModified: nil))

        index.verify([file("aqui.txt", id: "f1"), file("borrado.txt", id: "f2")], accountID: "google:1")
        for _ in 0..<100 where index.copies.count > 1 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(index.copies.values.map(\.fileID), ["f1"], "Only the entry whose file vanished is dropped")
        XCTAssertEqual(LocalCopyIndex(storeURL: index.storeURL).copies.count, 1, "The pruning is persisted")
    }

    func testMaintenanceOnlyTouchesICloudysOwnFolders() throws {
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertFalse(Maintenance.isOwned(outside))
        XCTAssertFalse(Maintenance.isOwned(URL(fileURLWithPath: "/")))
        XCTAssertFalse(Maintenance.isOwned(LocalStore.directory.deletingLastPathComponent()))
        XCTAssertTrue(Maintenance.isOwned(LocalStore.directory))
        XCTAssertTrue(Maintenance.isOwned(LocalStore.directory.appendingPathComponent("Listings")))
        for kind in Maintenance.Kind.allCases {
            if let directory = kind.directory { XCTAssertTrue(Maintenance.isOwned(directory), kind.rawValue) }
            XCTAssertFalse(kind.title.isEmpty)
            XCTAssertFalse(kind.detail.isEmpty)
        }
        XCTAssertTrue(Maintenance.Kind.localCopies.needsConfirmation, "Losing the marks is not a free cache drop")
        XCTAssertFalse(Maintenance.Kind.previews.needsConfirmation)
    }

    func testMaintenanceMeasuresAndEmptiesADirectoryWithoutRemovingIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("dentro"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 2048).write(to: root.appendingPathComponent("dentro/a.bin"))
        XCTAssertGreaterThanOrEqual(Maintenance.size(ofDirectory: root), 2048, "Sizes are counted recursively")
    }

    func testPreferencesFallBackToTheirDefaults() {
        let key = "icloudy-test-" + UUID().uuidString
        XCTAssertTrue(Prefs.bool(key, default: true))
        XCTAssertFalse(Prefs.bool(key, default: false))
        XCTAssertEqual(Prefs.int(key, default: 100), 100)
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(Prefs.bool(key, default: true), "A stored false must not read as the default true")
        UserDefaults.standard.removeObject(forKey: key)
    }
}
