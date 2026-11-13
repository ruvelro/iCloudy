import XCTest
@testable import iCloudy

/// iCloud Drive as a flavour of volume. The tests cannot make iCloud itself evict a file, so they cover what is ours:
/// which folders count, what the capability table says, and that items iCloud does not manage go the plain way.
@MainActor
final class ICloudDriveTests: XCTestCase {
    private func drive() throws -> URL {
        let root = try temporaryRoot().appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Docs"), withIntermediateDirectories: true)
        try Data("hola".utf8).write(to: root.appendingPathComponent("Docs/nota.txt"))
        return root
    }

    func testOnlyAFolderOfICloudDriveBecomesAnICloudAccount() throws {
        let root = try drive()
        let account = try AppModel.iCloudDriveAccount(folder: root, bookmark: nil)
        XCTAssertTrue(account.isICloudDrive)
        XCTAssertEqual(account.cloud, .volume, "Under the hood it is a volume")
        XCTAssertEqual(account.name, "iCloud Drive")
        XCTAssertEqual(account.serverURL, root.standardizedFileURL.path)
        let sub = try AppModel.iCloudDriveAccount(folder: root.appendingPathComponent("Docs"), bookmark: nil)
        XCTAssertEqual(sub.name, "Docs")
        XCTAssertThrowsError(try AppModel.iCloudDriveAccount(folder: try temporaryRoot(), bookmark: nil), "A folder outside iCloud Drive is refused")
    }

    func testTheCapabilityTableKnowsWhatICloudDriveChanges() throws {
        let account = try AppModel.iCloudDriveAccount(folder: try drive(), bookmark: nil)
        let capabilities = account.capabilities
        XCTAssertTrue(capabilities.ubiquitousItems)
        XCTAssertFalse(capabilities.quota, "The Mac's free space is not the iCloud plan's")
        XCTAssertEqual(capabilities.signIn, .folder)
        XCTAssertTrue(capabilities.thumbnails && capabilities.search && capabilities.permanentDelete, "The rest is still a volume")
        XCTAssertFalse(Cloud.volume.capabilities.ubiquitousItems, "A plain volume has no iCloud states")
    }

    func testFilesICloudDoesNotManageAreListedAndReadThePlainWay() async throws {
        let root = try drive()
        let api = CloudAPI(account: try AppModel.iCloudDriveAccount(folder: root, bookmark: nil))
        let files = try await api.list(parent: root.appendingPathComponent("Docs").path)
        XCTAssertEqual(files.map(\.name), ["nota.txt"])
        XCTAssertNil(files[0].ubiquity, "A file outside iCloud's management has no state to show")
        let destination = try temporaryRoot().appendingPathComponent("copia.txt")
        _ = try await api.download(file: files[0], to: destination)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "hola")
        let volume = try XCTUnwrap(api.provider as? VolumeProvider)
        try await volume.ensureDownloaded(URL(fileURLWithPath: files[0].id), interval: .zero)
    }

    func testTheStateIsNeverStoredWithTheFile() throws {
        var file = CloudFile(id: "/a", name: "a", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
        file.ubiquity = .cloudOnly
        let decoded = try JSONDecoder().decode(CloudFile.self, from: JSONEncoder().encode(file))
        XCTAssertNil(decoded.ubiquity, "What iCloud says now is read with each listing, not kept in a queue or a cache")
        XCTAssertEqual(Set([UbiquityState.cloudOnly, .downloading, .downloaded, .uploading].map(\.symbol)).count, 4)
    }
}
