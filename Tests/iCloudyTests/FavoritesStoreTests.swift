import XCTest
@testable import iCloudy

/// The favorites have one owner now: it reads the file, writes it in the background, and never writes an empty list
/// over one it could not read.
@MainActor
final class FavoritesStoreTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    private func file(_ id: String, folder: Bool = false) -> CloudFile {
        CloudFile(id: id, name: id, mime: folder ? "application/vnd.google-apps.folder" : "text/plain", size: 1,
                  modified: nil, webURL: nil, isFolder: folder)
    }

    func testAnUnreadableListIsSetAsideInsteadOfBeingOverwritten() throws {
        let url = folder.appendingPathComponent("favorites.json")
        let damaged = Data("[{\"accountID\": \"a\", \"file\": ".utf8)
        try damaged.write(to: url)

        let store = FavoritesStore(url: url)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertNotNil(store.loadError, "La persona se entera de que no se pudo leer")
        store.toggle(file("nuevo"), accountID: "a", path: [], collection: .files)
        StoreWriter.shared.flush(url)

        // The bug: the first star wrote `[nuevo]` over the only copy of every other favorite.
        let kept = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("favorites.json.corrupt-") }
        XCTAssertEqual(kept.count, 1, "El archivo dañado se aparta")
        XCTAssertEqual(try Data(contentsOf: kept[0]), damaged, "Con sus bytes intactos")
        XCTAssertEqual(FavoritesStore(url: url).items.map(\.file.id), ["nuevo"])
    }

    func testAListWrittenBeforeTheVersionFieldStillReads() throws {
        let url = folder.appendingPathComponent("favorites.json")
        try LocalStore.save([Favorite(accountID: "a", file: file("x"), path: [])], to: url)
        let store = FavoritesStore(url: url)
        XCTAssertEqual(store.items.map(\.id), ["a:x"])
        XCTAssertNil(store.loadError)

        store.toggle(file("y"), accountID: "a", path: [], collection: .files)
        StoreWriter.shared.flush(url)
        let written = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertEqual(written?["schemaVersion"] as? Int, 1)
    }

    func testChangesFollowTheItemAndAreWrittenInOneBurst() throws {
        let url = folder.appendingPathComponent("favorites.json")
        let store = FavoritesStore(url: url)
        var changes = 0
        store.didChange = { changes += 1 }
        let parent = file("carpeta", folder: true)
        store.toggle(parent, accountID: "a", path: [], collection: .files)
        store.toggle(file("dentro"), accountID: "a", path: [parent], collection: .files)
        store.toggle(file("otra"), accountID: "b", path: [], collection: .recent)
        XCTAssertTrue(store.contains(accountID: "a", fileID: "dentro"))

        store.moved(accountID: "b", fileID: "otra", to: [parent])
        XCTAssertEqual(store.items.first { $0.accountID == "b" }?.collection, .files, "Mover lo lleva a Mis archivos")

        store.remove(accountID: "a", fileID: "carpeta")
        XCTAssertEqual(store.items.map(\.id), ["b:otra"], "Lo que estaba dentro se va con la carpeta")
        store.remove(accountID: "a", fileID: "nada")
        XCTAssertEqual(changes, 5, "Quitar lo que no está no cuenta como cambio")

        StoreWriter.shared.flush(url)
        XCTAssertEqual(FavoritesStore(url: url).items.map(\.id), ["b:otra"])
    }
}
