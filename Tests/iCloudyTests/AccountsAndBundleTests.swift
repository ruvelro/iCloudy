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
