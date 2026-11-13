import XCTest
@testable import iCloudy

/// The operations Shortcuts, the command line and AppleScript share, over the demo account.
@MainActor
final class AutomationTests: XCTestCase {
    private func demoModel() throws -> (AppModel, DemoStore) {
        let model = AppModel()
        model.enableDemo()
        let demo = try XCTUnwrap(model.demo)
        demo.latency = .milliseconds(1)
        return (model, demo)
    }

    func testFoldersAreCreatedListedMovedAndRenamedByPath() async throws {
        let (model, _) = try demoModel()
        let created = try await model.automationCreateFolder(.demo, in: "Proyectos", name: "Nueva")
        XCTAssertEqual(created, "Proyectos/Nueva")
        let projects = try await model.automationList(.demo, path: "proyectos")
        XCTAssertTrue(projects.contains { $0.name == "Nueva" && $0.isFolder })

        try await model.automationMove(.demo, path: "Proyectos/Notas.txt", to: "Proyectos/Nueva", rename: nil)
        let moved = try await model.automationList(.demo, path: "Proyectos/Nueva")
        XCTAssertTrue(moved.contains { $0.name == "Notas.txt" })
        try await model.automationMove(.demo, path: "Proyectos/Nueva/Notas.txt", to: nil, rename: "Apuntes.txt")
        let renamed = try await model.automationList(.demo, path: "Proyectos/Nueva")
        XCTAssertEqual(renamed.map(\.name), ["Apuntes.txt"])

        do { try await model.automationMove(.demo, path: "Proyectos", to: nil, rename: nil); XCTFail("Nothing to do") } catch {}
        do { _ = try await model.automationCreateFolder(.demo, in: "", name: "a/b"); XCTFail("A slash is not a name") } catch {}
        do { _ = try await model.automationList(.demo, path: "Proyectos/Nueva/Apuntes.txt"); XCTFail("A file is not a folder") } catch {}
    }

    func testTheTrashIsAskedForWithWhatItWillDo() async throws {
        let (model, demo) = try demoModel()
        let (file, reversible) = try await model.automationTrashTarget(.demo, path: "Proyectos/Notas.txt")
        XCTAssertEqual(file.name, "Notas.txt")
        XCTAssertTrue(reversible, "The demo has a bin")
        try await model.automationTrash(.demo, file: file)
        let projects = try XCTUnwrap(demo.list("root").first { $0.name == "Proyectos" })
        XCTAssertFalse(try demo.list(projects.id).contains { $0.name == "Notas.txt" })
    }

    func testSearchReturnsItemsAndUploadsGoToTheNamedFolder() async throws {
        let (model, _) = try demoModel()
        let hits = await model.automationSearch("notas", in: .demo, limit: 5)
        XCTAssertTrue(hits.contains { $0.file.name == "Notas.txt" })
        let blank = await model.automationSearch("   ")
        XCTAssertTrue(blank.isEmpty)
        let entity = CloudItemEntity(try XCTUnwrap(hits.first), model: model)
        XCTAssertEqual(CloudItemQuery.hit(entity.id)?.file.name, entity.name, "A found item can be handed to Abrir en iCloudy")

        let local = try temporaryRoot().appendingPathComponent("subida.txt")
        try Data("x".utf8).write(to: local)
        let count = try await model.automationUpload([local], to: .demo, path: "Proyectos")
        XCTAssertEqual(count, 1)
        let job = try XCTUnwrap(model.queue.items.last)
        XCTAssertEqual(job.direction, .upload)
        XCTAssertTrue(job.destination.hasSuffix("Proyectos"), job.destination)
    }

    func testAnExpiringLinkNeedsAProviderThatSetsAnExpiry() async throws {
        let (model, _) = try demoModel()
        do { _ = try await model.automationExpiringLink(.demo, path: "Proyectos/Notas.txt", lifetime: 3600); XCTFail("The demo's links have no expiry") }
        catch { XCTAssertTrue(error.localizedDescription.contains("caducidad"), error.localizedDescription) }
    }

    func testTheShortcutsStayWithinWhatTheSystemOffers() {
        XCTAssertLessThanOrEqual(iCloudyShortcuts.appShortcuts.count, 10, "macOS shows at most ten App Shortcuts per app")
    }
}
