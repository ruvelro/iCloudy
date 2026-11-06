import XCTest
@testable import iCloudy

/// The explorer's write operations, undo and the version-history plumbing, through the demo account: the same model
/// code the window runs, against a local store instead of a provider.
@MainActor
final class AppModelOperationsTests: XCTestCase {
    private var model: AppModel!
    private var demo: DemoStore!

    override func setUp() async throws {
        model = AppModel()
        model.enableDemo()
        demo = try XCTUnwrap(model.demo)
        demo.latency = .milliseconds(1)
    }

    override func tearDown() async throws {
        model = nil; demo = nil
    }

    private func item(_ name: String, in parent: String = "root") throws -> CloudFile {
        try XCTUnwrap(demo.list(parent).first { $0.name == name }, "No «\(name)» in \(parent)")
    }
    private func names(in parent: String = "root") throws -> [String] { try demo.list(parent).map(\.name) }

    /// An undo manager that does not wait for the run loop to close its groups.
    private func undoManager() -> UndoManager {
        let manager = UndoManager()
        manager.groupsByEvent = false
        model.undoManager = manager
        return manager
    }
    private func registering(_ manager: UndoManager, _ body: () throws -> Void) rethrows {
        manager.beginUndoGrouping(); defer { manager.endUndoGrouping() }
        try body()
    }

    // MARK: - Undo

    func testOnlyBinsThatGiveAnItemBackByItsIDOfferUndo() {
        XCTAssertTrue(AppModel.undoesTrash(.demo))
        for cloud in [Cloud.google, .box, .pcloud, .mega] {
            XCTAssertTrue(AppModel.undoesTrash(stubbedAccount(cloud)), cloud.rawValue)
        }
        for cloud in [Cloud.dropbox, .microsoft, .webdav, .volume] {
            XCTAssertFalse(AppModel.undoesTrash(stubbedAccount(cloud)), "\(cloud.rawValue) needs more than the id to restore")
        }
    }

    func testARenameIsUndoneAndRedone() async throws {
        let manager = undoManager()
        let file = try item("Bienvenido.txt")
        let api = try model.client(.demo)
        try await model.applyRename(file, to: "Hola.txt", account: .demo, api: api)
        let renamed = try item("Hola.txt")
        registering(manager) { model.registerRenameUndo(file, renamed: renamed, account: .demo) }
        XCTAssertEqual(manager.undoActionName, L("Renombrar"))

        manager.undo()
        try await wait(until: { (try? self.names().contains("Bienvenido.txt")) == true }, "Undo renames it back")
        XCTAssertFalse(try names().contains("Hola.txt"))
        XCTAssertTrue(manager.canRedo)

        manager.redo()
        try await wait(until: { (try? self.names().contains("Hola.txt")) == true }, "Redo renames it again")
        XCTAssertNil(model.error)
    }

    func testAMoveFromTheFolderPickerCanBeUndone() async throws {
        let manager = undoManager()
        let folder = try item("Proyectos"), file = try item("Bienvenido.txt")
        manager.beginUndoGrouping()
        await model.relocate(Relocation(files: [file], kind: .move, account: .demo, origin: "root"), to: folder.id, destinationPath: [folder])
        manager.endUndoGrouping()
        XCTAssertNil(model.error)
        XCTAssertTrue(try names(in: folder.id).contains("Bienvenido.txt"))
        XCTAssertFalse(try names().contains("Bienvenido.txt"))
        XCTAssertNotNil(model.info, "The move is reported")
        XCTAssertEqual(manager.undoActionName, L("Mover"))

        manager.undo()
        try await wait(until: { (try? self.names().contains("Bienvenido.txt")) == true }, "Undo moves it back")
        XCTAssertFalse(try names(in: folder.id).contains("Bienvenido.txt"))
    }

    func testBinningFromTheDemoIsUndoneByRestoring() async throws {
        let manager = undoManager()
        let file = try item("Bienvenido.txt")
        manager.beginUndoGrouping()
        await model.trash([file])
        manager.endUndoGrouping()
        XCTAssertNil(model.error)
        XCTAssertFalse(try names().contains("Bienvenido.txt"))
        XCTAssertTrue(try names(in: Collection.trash.rootID).contains("Bienvenido.txt"))

        manager.undo()
        try await wait(until: { (try? self.names().contains("Bienvenido.txt")) == true }, "Undo takes it out of the bin")
        XCTAssertFalse(try names(in: Collection.trash.rootID).contains("Bienvenido.txt"))
    }

    func testAFailedUndoClearsTheHistoryAndSaysWhy() async throws {
        let manager = undoManager()
        let file = try item("Bienvenido.txt")
        let api = try model.client(.demo)
        try await model.applyRename(file, to: "Hola.txt", account: .demo, api: api)
        let renamed = try item("Hola.txt")
        registering(manager) { model.registerRenameUndo(file, renamed: renamed, account: .demo) }
        demo.offline = true
        manager.undo()
        try await wait(until: { self.model.error != nil }, "The failure is shown")
        XCTAssertFalse(manager.canUndo); XCTAssertFalse(manager.canRedo)
        XCTAssertTrue(try { demo.offline = false; return try names().contains("Hola.txt") }(), "Nothing was renamed")
    }

    // MARK: - File operations

    func testAFolderCannotGoInsideItself() async throws {
        let folder = try item("Proyectos")
        await model.relocate(Relocation(files: [folder], kind: .move, account: .demo, origin: "root"), to: folder.id, destinationPath: [folder])
        XCTAssertEqual(model.error, L("Una carpeta no puede moverse ni copiarse dentro de sí misma."))
        XCTAssertTrue(try names().contains("Proyectos"))
    }

    func testCopyingOntoANameThatIsAlreadyThereIsRefused() async throws {
        let folder = try item("Proyectos")
        _ = try demo.add(name: "bienvenido.TXT", parent: folder.id, content: Data("otro".utf8))
        let file = try item("Bienvenido.txt")
        await model.relocate(Relocation(files: [file], kind: .copy, account: .demo, origin: "root"), to: folder.id, destinationPath: [folder])
        XCTAssertTrue(model.error?.contains("Bienvenido.txt") == true, model.error ?? "no error")
        XCTAssertEqual(try names(in: folder.id).filter { $0.lowercased() == "bienvenido.txt" }.count, 1, "Nothing was copied")
    }

    func testCopyLeavesTheOriginalWhereItWas() async throws {
        let folder = try item("Proyectos"), file = try item("Bienvenido.txt")
        await model.relocate(Relocation(files: [file], kind: .copy, account: .demo, origin: "root"), to: folder.id, destinationPath: [folder])
        XCTAssertNil(model.error)
        XCTAssertTrue(try names().contains("Bienvenido.txt"))
        XCTAssertTrue(try names(in: folder.id).contains("Bienvenido.txt"))
    }

    func testBinRestoreAndPermanentDeleteFromTheDemo() async throws {
        let file = try item("Bienvenido.txt")
        await model.trash([file])
        await model.restore([file])
        XCTAssertNil(model.error)
        XCTAssertTrue(try names().contains("Bienvenido.txt"), "Restored to its folder")

        await model.trash([file])
        await model.deletePermanently([file])
        XCTAssertNil(model.error)
        XCTAssertFalse(try names(in: Collection.trash.rootID).contains("Bienvenido.txt"))
        XCTAssertFalse(try names().contains("Bienvenido.txt"))
    }

    func testDeletingAFavouriteForgetsTheFavourite() async throws {
        let file = try item("Bienvenido.txt")
        model.favoriteStore.toggle(file, accountID: Account.demo.id, path: [], collection: .files)
        XCTAssertEqual(model.favorites.count, 1)
        await model.trash([file])
        XCTAssertTrue(model.favorites.isEmpty, "A favourite that points at the bin is gone")
    }

    // MARK: - Versions

    func testTheDemoHasNoVersionsAndSaysSoBeforeTrying() async throws {
        let file = try item("Bienvenido.txt")
        let reason = try XCTUnwrap(model.versionsLimitation(file))
        XCTAssertFalse(reason.isEmpty)
        let request = VersionsRequest(file: file, account: .demo, parent: "root", location: "Demo")
        let version = FileVersion(id: "v1", modified: Date(), size: 3, isCurrent: false)
        do { try await model.restoreVersion(version, of: request); XCTFail("The demo keeps no history") }
        catch { XCTAssertEqual(error.localizedDescription, Account.demo.versionsUnavailable) }
    }

    func testAVersionTargetNamesTheVersionUnlessItIsTheCurrentOne() {
        let file = CloudFile(id: "f", name: "informe.pdf", mime: "application/pdf", size: 10, modified: nil, webURL: nil, isFolder: false)
        let current = FileVersion(id: "now", modified: nil, size: 10, isCurrent: true)
        XCTAssertEqual(AppModel.versionTarget(current, of: file).id, file.id)
        let old = FileVersion(id: "v1", modified: Date(timeIntervalSince1970: 0), size: 7, isCurrent: false)
        let target = AppModel.versionTarget(old, of: file)
        XCTAssertNotEqual(target.id, file.id)
        XCTAssertEqual(VersionedFile.reference(target)?.file.id, file.id)
    }

    func testARestoreLeavesACompletedNoteInTheHistory() {
        let file = CloudFile(id: "f", name: "informe.pdf", mime: "application/pdf", size: 10, modified: nil, webURL: nil, isFolder: false)
        let request = VersionsRequest(file: file, account: .demo, parent: "carpeta", location: "Demo / Carpeta")
        let note = AppModel.restoreNote(FileVersion(id: "v1", modified: nil, size: 7, isCurrent: false), of: request)
        XCTAssertEqual(note.state, .completed)
        XCTAssertEqual(note.name, "informe.pdf")
        XCTAssertEqual(note.destination, "Demo / Carpeta")
        XCTAssertEqual(note.total, 7)
        XCTAssertTrue(note.detail.contains("v1"), note.detail)
    }
}
