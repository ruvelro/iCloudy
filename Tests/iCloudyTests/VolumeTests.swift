import XCTest
@testable import iCloudy

@MainActor
final class VolumeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("volumen-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Fotos/Viaje"), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 5000).write(to: root.appendingPathComponent("Fotos/playa.jpg"))
        try Data("hola".utf8).write(to: root.appendingPathComponent("nota.txt"))
        try Data("x".utf8).write(to: root.appendingPathComponent("Fotos/Viaje/mapa.pdf"))
    }
    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }
    /// A volume account needs no credentials at all: the bookmark is what grants access.
    private func client() -> CloudAPI {
        CloudAPI(account: Account(id: "volume:test", cloud: .volume, name: "Prueba", email: "local",
                                  clientID: "", clientSecret: nil, serverURL: root.standardizedFileURL.path))
    }

    func testListsFoldersFirstAndReadsSizes() async throws {
        let files = try await client().list(parent: "root")
        XCTAssertEqual(files.map(\.name), ["Fotos", "nota.txt"])
        XCTAssertTrue(files[0].isFolder)
        XCTAssertNil(files[0].size, "Una carpeta no declara tamaño")
        XCTAssertEqual(files[1].size, 4)
        XCTAssertEqual(files[1].mime, "text/plain")
        XCTAssertNotNil(files[1].modified)
        let inside = try await client().list(parent: root.appendingPathComponent("Fotos").path)
        XCTAssertEqual(inside.map(\.name), ["Viaje", "playa.jpg"])
    }

    func testSymbolicLinksAreListedButNeverBrowsedAsFolders() async throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("atajo"), withDestinationURL: root.appendingPathComponent("Fotos"))
        let files = try await client().list(parent: "root")
        let link = try XCTUnwrap(files.first { $0.name == "atajo" })
        XCTAssertFalse(link.isFolder, "Seguir un enlace permitiría salir de la carpeta conectada")
    }

    func testIdentifiersCannotEscapeTheConnectedFolder() async throws {
        let api = client()
        XCTAssertEqual(try api.volumeURL("root").standardizedFileURL.path, root.standardizedFileURL.path)
        XCTAssertNoThrow(try api.volumeURL(root.appendingPathComponent("Fotos").path))
        for outside in ["/etc/passwd", root.deletingLastPathComponent().path, root.appendingPathComponent("../fuera").path] {
            XCTAssertThrowsError(try api.volumeURL(outside), outside) { error in
                XCTAssertTrue(error.localizedDescription.contains("fuera de la carpeta"), error.localizedDescription)
            }
        }
    }

    func testCreateRenameMoveAndCopyWorkOnDisk() async throws {
        let api = client()
        let folder = try await api.createFolder(name: "Nueva", parent: "root")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder))
        let atStart = try await api.list(parent: "root")
        let note = try XCTUnwrap(atStart.first { $0.name == "nota.txt" })

        try await api.rename(file: note, name: "apunte.txt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("apunte.txt").path))
        let afterRename = try await api.list(parent: "root")
        let renamed = try XCTUnwrap(afterRename.first { $0.name == "apunte.txt" })

        try await api.move(file: renamed, to: folder)
        let inFolder = try await api.list(parent: folder)
        XCTAssertEqual(inFolder.map(\.name), ["apunte.txt"])
        let moved = try XCTUnwrap(inFolder.first)
        try await api.copy(file: moved, to: "root")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("apunte.txt")), Data("hola".utf8))

        // Copying onto an existing name must refuse rather than overwrite silently.
        do { try await api.copy(file: moved, to: "root"); XCTFail("Debe negarse a sobrescribir") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Ya existe"), error.localizedDescription) }
    }

    func testDownloadAndUploadCopyTheBytes() async throws {
        let api = client()
        let photos = try await api.list(parent: root.appendingPathComponent("Fotos").path)
        let photo = try XCTUnwrap(photos.first { $0.name == "playa.jpg" })
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: destination) }
        var progress: [Int64] = []
        try await api.download(file: photo, to: destination) { sent, _ in progress.append(sent) }
        XCTAssertEqual(try Data(contentsOf: destination), Data(repeating: 7, count: 5000))
        XCTAssertEqual(progress.last, 5000)

        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("subida".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let checkpoint = UploadCheckpoint(total: 6, modified: try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        let receipt = try await api.resumableUpload(local: source, parent: "root", name: "subida.txt", replacing: nil,
                                                    checkpoint: checkpoint, save: { _ in }, progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("subida.txt")), Data("subida".utf8))
        XCTAssertEqual(receipt.verification, .unavailable, "Una copia local no tiene suma remota que comparar")
    }

    func testSearchWalksTheTreeAndReportsTruncation() async throws {
        let page = try await client().searchPage(term: "MAPA")
        XCTAssertEqual(page.hits.map(\.file.name), ["mapa.pdf"], "La búsqueda no distingue mayúsculas")
        XCTAssertEqual(page.hits.first?.parentID, root.appendingPathComponent("Fotos/Viaje").standardizedFileURL.path)
        XCTAssertNil(page.next, "La búsqueda local no pagina")
        XCTAssertFalse(page.incomplete)
        let empty = try await client().searchPage(term: "   ")
        XCTAssertTrue(empty.hits.isEmpty, "Una búsqueda vacía no recorre el disco")
    }

    func testBreadcrumbsAreBuiltFromThePath() throws {
        let trail = try client().volumeTrail(id: root.appendingPathComponent("Fotos/Viaje").path)
        XCTAssertEqual(trail.map(\.name), ["Fotos", "Viaje"])
        XCTAssertTrue(trail.allSatisfy(\.isFolder))
        XCTAssertTrue(try client().volumeTrail(id: "root").isEmpty)
    }

    func testQuotaComesFromTheVolumeItself() async throws {
        let quota = try await client().storageQuota()
        XCTAssertGreaterThan(quota.total ?? 0, 0)
        XCTAssertGreaterThanOrEqual(quota.used, 0)
        XCTAssertLessThanOrEqual(quota.used, quota.total ?? 0)
    }

    func testAnUnmountedVolumeSaysSoInsteadOfFailingObscurely() async throws {
        let api = client()
        try FileManager.default.removeItem(at: root)
        do { _ = try await api.list(parent: "root"); XCTFail("Debe avisar de que no está montado") }
        catch { XCTAssertTrue(error.localizedDescription.contains("no está montado"), error.localizedDescription) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func testCapabilitiesReflectWhatAFileSystemCanDo() {
        let volume = Cloud.volume.capabilities
        XCTAssertTrue(volume.search, "Recorrer el árbol es barato y no depende de ningún índice ajeno")
        XCTAssertTrue(volume.reversibleTrash, "trashItem deja el elemento en la papelera del usuario")
        XCTAssertTrue(volume.quota)
        XCTAssertTrue(volume.copy)
        XCTAssertFalse(volume.publicLinks)
        XCTAssertFalse(volume.oauth)
        XCTAssertFalse(volume.usesPasswordLoginForTesting, "Un volumen se conecta eligiendo carpeta, no con contraseña")
        XCTAssertTrue(Cloud.volume.isSelfHosted)
    }
}

private extension CloudCapabilities {
    /// Mirrors `Cloud.usesPasswordLogin` so the expectation reads next to the other capabilities.
    var usesPasswordLoginForTesting: Bool { Cloud.volume.usesPasswordLogin }
}
