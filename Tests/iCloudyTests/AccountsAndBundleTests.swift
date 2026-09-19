import XCTest
@testable import iCloudy

/// What the explorer acts on, what leaves with an account, and what the bundle promises macOS. All three are pure
/// functions or files, so they are checked without a window, a Keychain or a signed build.
@MainActor
final class AccountsAndBundleTests: XCTestCase {
    private func file(_ id: String, _ name: String) -> CloudFile {
        CloudFile(id: id, name: name, mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false)
    }

    func testAMultiSelectionActsOnlyOnWhatTheListShows() {
        // Filtering the list keeps the ids of the hidden rows selected. ⌫ and "Descargar selección" then acted on
        // five files while the person was looking at one; now they act on the visible ones alone.
        let all = [file("1", "informe.pdf"), file("2", "foto.jpg"), file("3", "informe viejo.pdf")]
        let visible = all.filter { $0.name.contains("informe") }
        let selected: Set<String> = ["1", "2", "3"]
        XCTAssertEqual(AppModel.selected(selected, among: visible).map(\.id), ["1", "3"])
        XCTAssertEqual(AppModel.selected(selected, among: all).map(\.id), ["1", "2", "3"])
        XCTAssertTrue(AppModel.selected(["9"], among: all).isEmpty)
    }

    func testSharedDrivesLeaveWithTheAccountTheyBorrowFrom() {
        // A scoped account has no sign-in of its own. Disconnecting the parent used to delete the shared credential
        // and leave the drives behind, marked expired, with no way back.
        let parent = Account(id: "google:ana", cloud: .google, name: "Ana", email: "ana@ejemplo.com", clientID: "id", clientSecret: nil)
        let other = Account(id: "google:luis", cloud: .google, name: "Luis", email: "luis@ejemplo.com", clientID: "id", clientSecret: nil)
        let drive = Account.scoped(to: "0ABC", named: "Marketing", from: parent)
        let library = Account.scoped(to: "b!lib", named: "Documentos", from: parent)
        let theirs = Account.scoped(to: "0XYZ", named: "Ventas", from: other)
        let all = [parent, drive, other, library, theirs]
        XCTAssertEqual(AppModel.dependents(of: parent, in: all).map(\.id), [drive.id, library.id])
        XCTAssertEqual(AppModel.dependents(of: other, in: all).map(\.id), [theirs.id])
        XCTAssertTrue(AppModel.dependents(of: drive, in: all).isEmpty, "A drive has no dependants of its own")
        XCTAssertTrue(AppModel.dependents(of: parent, in: [parent]).isEmpty)
    }

    func testOnlyOneAlertAtATimeAndTheErrorGoesFirst() {
        // SwiftUI presents one alert at a time, so an error and a piece of good news arriving together meant the
        // second never appeared. Sending files to the bin and reloading right after did exactly that.
        let model = AppModel()
        XCTAssertNil(model.alertMessage)
        model.info = "Enlace copiado"
        XCTAssertEqual(model.alertMessage, "Enlace copiado")
        XCTAssertEqual(model.alertTitle, L("iCloudy"))
        model.error = "No se pudo borrar"
        XCTAssertEqual(model.alertMessage, "No se pudo borrar", "El error va primero")
        XCTAssertEqual(model.alertTitle, L("No se pudo completar la operación"))
        model.dismissAlert()
        XCTAssertEqual(model.alertMessage, "Enlace copiado", "Y la otra espera su turno en vez de perderse")
        model.dismissAlert()
        XCTAssertNil(model.alertMessage)
    }

    func testTakingARunOfFilesWithShift() {
        // The grid had no equivalent of shift-picking a run, so taking twenty files meant twenty Command-clicks.
        let files = (1...5).map { CloudFile(id: "\($0)", name: "a\($0).txt", mime: "text/plain", size: 1, modified: nil, webURL: nil, isFolder: false) }
        XCTAssertEqual(ExplorerView.range(from: "2", to: "4", in: files), ["2", "3", "4"])
        XCTAssertEqual(ExplorerView.range(from: "4", to: "2", in: files), ["2", "3", "4"], "El orden en que se pulsan da igual")
        XCTAssertEqual(ExplorerView.range(from: "3", to: "3", in: files), ["3"])
        XCTAssertEqual(ExplorerView.range(from: "9", to: "3", in: files), ["3"], "Un ancla que ya no está deja solo lo pulsado")
    }

    func testTheUserOfAnAccountIsRecoveredForReconnecting() {
        // Reconnecting is about a session, not about an address: asking for the server and the user again from
        // memory is a poor way of asking somebody for a password.
        let webdav = Account(id: "webdav:nas.local/dav#ana", cloud: .webdav, name: "nas.local", email: "ana@nas.local",
                             clientID: "", clientSecret: nil, serverURL: "https://nas.local/dav")
        XCTAssertEqual(ServerLoginView.storedUser(of: webdav), "ana")
        let ftp = Account(id: "ftp:nas.local:21/carpeta#operador", cloud: .ftp, name: "nas.local", email: "operador@nas.local",
                          clientID: "", clientSecret: nil, serverURL: "ftp://nas.local/carpeta")
        XCTAssertEqual(ServerLoginView.storedUser(of: ftp), "operador")
        let mega = Account(id: "mega:ana@ejemplo.com", cloud: .mega, name: "Mega", email: "ana@ejemplo.com", clientID: "", clientSecret: nil)
        XCTAssertEqual(ServerLoginView.storedUser(of: mega), "ana@ejemplo.com", "Mega se identifica con el correo entero")
    }

    func testTheBundleDeclaresWhatTheDockAndShortcutsNeed() throws {
        // Dropping on the Dock icon only works when the app says what it opens; without CFBundleDocumentTypes the
        // Finder never calls application(_:open:). Shortcuts only lists intents when Metadata.appintents is in the
        // bundle, which `swift build` does not produce, so the build script has to.
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "Resources/Info.plist")), format: nil) as? [String: Any]
        let types = try XCTUnwrap(plist?["CFBundleDocumentTypes"] as? [[String: Any]])
        let accepted = Set(types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] })
        XCTAssertTrue(accepted.isSuperset(of: ["public.item", "public.folder"]), accepted.description)
        XCTAssertEqual(types.first?["LSHandlerRank"] as? String, "None", "iCloudy uploads files; it is nobody's editor")
        XCTAssertNotNil(plist?["NSServices"], "The Services menu entry is still declared")
        XCTAssertFalse((plist?["NSHumanReadableCopyright"] as? String ?? "").contains("Google Drive y OneDrive"), "Nine providers, not two")

        let script = try String(contentsOf: URL(fileURLWithPath: "scripts/build-app.sh"), encoding: .utf8)
        XCTAssertTrue(script.contains("appintentsmetadataprocessor"))
        XCTAssertTrue(script.contains("-emit-const-values"), "The processor reads the constant values the compiler extracts")
        XCTAssertTrue(script.contains("Metadata.appintents"))
    }
}
