import XCTest
import UniformTypeIdentifiers
@testable import iCloudy

/// The Finder extension cannot be run here (it needs a Team ID to be signed into the bundle), but everything it
/// relies on can: the item shape, the index it remembers items in, the domain bookkeeping and the backend it talks
/// to, exercised against the demo store.
@MainActor
final class FileProviderTests: XCTestCase {
    func testItemsCarryTheirParentAndAUniformTypeBothWays() {
        let file = CloudFile(id: "f1", name: "foto.jpg", mime: "image/jpeg", size: 12, modified: Date(timeIntervalSince1970: 5), webURL: nil, isFolder: false)
        let item = FPItem(file, parent: "root")
        XCTAssertEqual(item.parentID, "root"); XCTAssertEqual(item.contentType, UTType.jpeg.identifier); XCTAssertEqual(item.size, 12)
        XCTAssertEqual(item.cloudFile().mime, "image/jpeg")
        let folder = FPItem(CloudFile(id: "d", name: "Docs", mime: "application/vnd.google-apps.folder", size: nil, modified: nil, webURL: nil, isFolder: true), parent: "root")
        XCTAssertEqual(folder.contentType, UTType.folder.identifier); XCTAssertTrue(folder.cloudFile().isFolder)
        let unknown = FPItem(CloudFile(id: "x", name: "datos", mime: "application/octet-stream", size: 1, modified: nil, webURL: nil, isFolder: false), parent: "d")
        XCTAssertEqual(unknown.contentType, UTType.data.identifier)
    }

    func testTheIndexSurvivesARelaunchAndDropsWhatAListingNoLongerShows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fp-index-\(UUID().uuidString)/index.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let make = { (id: String, parent: String) in FPItem(id: id, parentID: parent, name: id, isFolder: false, size: 1, modified: nil, contentType: UTType.data.identifier) }
        let index = FileProviderIndex(url: url)
        index.remember([make("a", "root"), make("b", "root"), make("c", "sub")])
        XCTAssertEqual(FileProviderIndex(url: url).item("b")?.parentID, "root", "Lo recordado se lee de disco en otro proceso")
        index.replaceChildren(of: "root", with: [make("a", "root"), make("d", "root")])
        XCTAssertNil(index.item("b"), "b ya no está en la nube")
        XCTAssertNotNil(index.item("c"), "Los hijos de otra carpeta no se tocan")
        XCTAssertEqual(Set(index.children(of: "root").map(\.id)), ["a", "d"])
        index.forget("d")
        XCTAssertNil(FileProviderIndex(url: url).item("d"))
    }

    func testDomainsFollowTheAccountsWhileTheIntegrationIsOn() {
        let drive = Account(id: "g1", cloud: .google, name: "", email: "ana@example.com", clientID: "", clientSecret: nil)
        let volume = Account(id: "v1", cloud: .volume, name: "", email: "local", clientID: "", clientSecret: nil, serverURL: "/tmp")
        let wanted = FileProviderShared.domains(for: [drive, volume, .demo])
        XCTAssertEqual(wanted.map(\.id), ["g1"], "Ni la demo ni un volumen del propio Mac son un dominio del Finder")
        XCTAssertEqual(wanted.first?.name, "Google Drive · ana@example.com")
        let plan = FileProviderDomains.changes(current: ["g1", "old"], accounts: [drive, volume], enabled: true)
        XCTAssertTrue(plan.add.isEmpty); XCTAssertEqual(plan.remove, ["old"])
        let off = FileProviderDomains.changes(current: ["g1"], accounts: [drive], enabled: false)
        XCTAssertEqual(off.remove, ["g1"], "Apagar la integración retira los dominios")
        let fresh = FileProviderDomains.changes(current: [], accounts: [drive], enabled: true)
        XCTAssertEqual(fresh.add.map(\.id), ["g1"])
        XCTAssertNil(FileProviderShared.groupIdentifier, "Sin App Group en el bundle no se exporta nada")
        XCTAssertFalse(FileProviderDomains.extensionPresent, "El paquete de pruebas no lleva la extensión")
    }

    func testTheBackendDrivesAProviderEndToEnd() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("fp-backend-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let demo = try DemoStore(directory: base.appendingPathComponent("demo")); demo.latency = .zero
        let backend = FileProviderBackend(api: CloudAPI(account: .demo, demo: demo))
        let root = try await backend.list(folder: FPItem.rootID)
        XCTAssertTrue(root.contains { $0.name == "Proyectos" && $0.isFolder })
        XCTAssertTrue(root.allSatisfy { $0.parentID == FPItem.rootID })

        let folder = try await backend.createFolder(named: "Finder", in: FPItem.rootID)
        let local = base.appendingPathComponent("subida.txt"); try Data("desde el Finder".utf8).write(to: local)
        var file = try await backend.upload(local, named: "subida.txt", in: folder.id, replacing: nil)
        XCTAssertEqual(file.parentID, folder.id); XCTAssertEqual(file.size, 15); XCTAssertEqual(file.contentType, UTType.plainText.identifier)
        file = try await backend.rename(file, to: "renombrado.txt")
        XCTAssertEqual(file.name, "renombrado.txt")
        file = try await backend.move(file, to: FPItem.rootID)
        XCTAssertEqual(file.parentID, FPItem.rootID)
        let listed = try await backend.list(folder: FPItem.rootID)
        XCTAssertTrue(listed.contains { $0.id == file.id && $0.name == "renombrado.txt" })

        let downloaded = base.appendingPathComponent("bajada.txt")
        try await backend.download(file, to: downloaded)
        XCTAssertEqual(try String(contentsOf: downloaded, encoding: .utf8), "desde el Finder")
        try await backend.delete(file)
        let after = try await backend.list(folder: FPItem.rootID)
        XCTAssertFalse(after.contains { $0.id == file.id })
        XCTAssertNil(FileProviderBackend(accountID: "nadie"), "Sin cuenta exportada no hay backend")
    }
}
