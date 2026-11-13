import XCTest
@testable import iCloudy

/// «Espacio» adds up what a tree lists. The tree here is a table, so every figure can be checked by hand.
@MainActor
final class UsageScannerTests: XCTestCase {
    private final class Tree: InventorySource {
        let caseSensitive = true, hashesLocally = false
        var folders: [String: [InventoryEntry]] = [:]
        var listed: [String] = []
        func children(of folder: InventoryEntry?) async throws -> [InventoryEntry] {
            let key = folder?.file?.id ?? "root"
            listed.append(key)
            return folders[key] ?? []
        }
        func digest(of entry: InventoryEntry, algorithm: ContentHash.Algorithm) async throws -> String { "" }
    }
    private func file(_ id: String, _ size: Int64?, mime: String = "text/plain") -> InventoryEntry {
        InventoryEntry(file: CloudFile(id: id, name: id, mime: mime, size: size, modified: nil, webURL: nil, isFolder: false))
    }
    private func folder(_ id: String) -> InventoryEntry {
        InventoryEntry(file: CloudFile(id: id, name: id, mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true))
    }
    private func tree() -> Tree {
        let tree = Tree()
        tree.folders["root"] = [file("pequeño.txt", 10), folder("Fotos"), folder("Vacía"), file("Documento", nil, mime: "application/vnd.google-apps.document")]
        tree.folders["Fotos"] = [file("a.jpg", 300), folder("2026"), file("b.jpg", 200)]
        tree.folders["2026"] = [file("vídeo.mov", 5000)]
        return tree
    }

    func testEveryFolderCarriesTheSumOfWhatIsBelowIt() async throws {
        let result = try await UsageScanner.scan(tree(), name: "Cuenta")
        let root = result.root
        XCTAssertEqual(root.name, "Cuenta")
        XCTAssertEqual(root.size, 5510); XCTAssertEqual(root.files, 5)
        XCTAssertEqual(root.unsized, 1, "A Google document is counted and never weighed")
        XCTAssertEqual(root.children.map(\.name), ["Fotos", "pequeño.txt", "Documento", "Vacía"], "Largest first, names breaking the ties")
        let photos = try XCTUnwrap(root.descendant(["cloud:Fotos"]))
        XCTAssertEqual(photos.size, 5500); XCTAssertEqual(photos.files, 3)
        XCTAssertEqual(photos.children.map(\.name), ["2026", "a.jpg", "b.jpg"])
        XCTAssertEqual(root.descendant(["cloud:Fotos", "cloud:2026"])?.size, 5000)
        XCTAssertNil(root.descendant(["cloud:Fotos", "no existe"]))
        XCTAssertEqual(result.progress, UsageScanner.Progress(folders: 4, files: 5, bytes: 5510))
        XCTAssertFalse(result.truncated)
    }

    func testTheLargestFilesComeWithTheFolderTheyAreIn() async throws {
        let root = try await UsageScanner.scan(tree(), name: "Cuenta").root
        let largest = root.largestFiles(limit: 3)
        XCTAssertEqual(largest.map(\.node.name), ["vídeo.mov", "a.jpg", "b.jpg"])
        XCTAssertEqual(largest.map(\.trail), [["Fotos", "2026"], ["Fotos"], ["Fotos"]])
    }

    func testAWalkPastTheLimitStopsAndSaysSo() async throws {
        let source = tree()
        let result = try await UsageScanner.scan(source, name: "Cuenta", limit: 3)
        XCTAssertTrue(result.truncated)
        XCTAssertLessThanOrEqual(result.progress.folders + result.progress.files, 3)
        XCTAssertFalse(source.listed.contains("2026"), "Nothing is listed past the limit")
    }

    func testProgressArrivesAsTheWalkGoes() async throws {
        var seen: [UsageScanner.Progress] = []
        _ = try await UsageScanner.scan(tree(), name: "Cuenta") { seen.append($0) }
        XCTAssertEqual(seen.count, 4, "Once per folder")
        XCTAssertEqual(seen.last?.bytes, 5510)
    }

    func testCancellingStopsTheWalk() async throws {
        let source = tree()
        let task = Task { try await UsageScanner.scan(source, name: "Cuenta") }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled before it started") } catch is CancellationError {}
        XCTAssertTrue(source.listed.isEmpty)
    }
}
