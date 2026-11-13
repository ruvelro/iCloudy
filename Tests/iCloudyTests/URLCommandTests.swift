import XCTest
@testable import iCloudy

/// `icloudy://` links: what they may ask for, what they may not, and where they take the window.
@MainActor
final class URLCommandTests: XCTestCase {
    private func parse(_ text: String) throws -> URLCommand { try URLCommand.parse(URL(string: text)!) }

    func testTheThreeCommandsAndTheShortForm() throws {
        XCTAssertEqual(try parse("icloudy://open?account=demo:local&path=/Proyectos/Notas.txt"), .open(account: "demo:local", path: ["Proyectos", "Notas.txt"]))
        XCTAssertEqual(try parse("icloudy://reveal?account=Trabajo&path=Fotos%2F2024"), .reveal(account: "Trabajo", path: ["Fotos", "2024"]))
        XCTAssertEqual(try parse("icloudy://search?q=%20factura%20"), .search(query: "factura"))
        XCTAssertEqual(try parse("ICLOUDY://Trabajo/Fotos/Playa%20azul"), .open(account: "Trabajo", path: ["Fotos", "Playa azul"]))
        XCTAssertEqual(try parse("icloudy://open?account=a"), .open(account: "a", path: []), "No path is the top of the account")
    }

    func testWhatALinkMayNotDo() throws {
        XCTAssertThrowsError(try parse("https://open?account=a"))
        XCTAssertThrowsError(try parse("icloudy://open?path=/a"), "An account is required")
        XCTAssertThrowsError(try parse("icloudy://open?account=a&path=/a/../../etc"), "A link names a place, it does not walk out of one")
        XCTAssertThrowsError(try parse("icloudy://open?account=a&path=/a/%0Ab"), "No control characters")
        XCTAssertThrowsError(try parse("icloudy://search?q="))
        for verb in ["delete", "trash", "move", "rename", "upload", "empty"] {
            XCTAssertThrowsError(try parse("icloudy://\(verb)?account=a&path=/x"), "\(verb) is never done from a link")
        }
        XCTAssertThrowsError(try parse("icloudy://search?q=" + String(repeating: "a", count: 9000)), "Too long")
        XCTAssertEqual(try parse("icloudy://search?q=" + String(repeating: "a", count: 400)), .search(query: String(repeating: "a", count: 256)))
    }

    func testALinkRoundTrips() throws {
        let command = URLCommand.reveal(account: "webdav:nas#ana", path: ["Fotos", "año nuevo & más.jpg"])
        let link = try XCTUnwrap(URLCommand.link(command))
        XCTAssertEqual(try URLCommand.parse(link), command)
    }

    func testAnOpenLinkShowsTheFolderAndARevealSelectsTheItem() async throws {
        let model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        XCTAssertEqual(try model.account(named: "DEMO LOCAL").id, Account.demo.id, "An account is found by its name, ignoring case")
        XCTAssertThrowsError(try model.account(named: "nadie"))

        await model.handle(URL(string: "icloudy://open?account=demo:local&path=/proyectos")!)
        XCTAssertEqual(model.path.map(\.name), ["Proyectos"])
        await model.handle(URL(string: "icloudy://reveal?account=demo:local&path=/Proyectos/notas.txt")!)
        XCTAssertEqual(model.path.map(\.name), ["Proyectos"], "Reveal opens the folder that holds the item")
        let notes = try XCTUnwrap(model.demo?.list(model.path.last!.id).first { $0.name == "Notas.txt" })
        XCTAssertEqual(model.selectedIDs, [notes.id])

        await model.handle(URL(string: "icloudy://delete?account=demo:local&path=/Proyectos")!)
        XCTAssertNotNil(model.error, "A refused link says why")
        XCTAssertNotNil(try model.demo?.list("root").first { $0.name == "Proyectos" }, "And touches nothing")
    }

    func testTheBundleDeclaresTheScheme() throws {
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repositoryURL("Resources/Info.plist")))
        let types = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        XCTAssertEqual(types.flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }, ["icloudy"])
    }
}
