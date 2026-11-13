import XCTest
import AppKit
@testable import iCloudy

/// The scripting dictionary and the classes it names: a dictionary whose class is missing loads fine and then fails
/// every script with a generic error, which nothing would notice before a person tried.
final class AppleScriptTests: XCTestCase {
    func testTheDictionaryNamesClassesThatExistAndOnlyReads() throws {
        let data = try Data(contentsOf: repositoryURL("Resources/iCloudy.sdef"))
        let document = try XMLDocument(data: data)
        let commands = try document.nodes(forXPath: "//command")
        XCTAssertEqual(commands.compactMap { ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue }, ["list accounts", "show", "search for"])
        let classes = try document.nodes(forXPath: "//command/cocoa/@class").compactMap(\.stringValue)
        XCTAssertEqual(classes.count, 3)
        for name in classes {
            let found: AnyClass = try XCTUnwrap(NSClassFromString(name), "\(name) is registered with the Objective-C runtime")
            XCTAssertTrue(found.isSubclass(of: NSScriptCommand.self), name)
        }
        let codes = try document.nodes(forXPath: "//command/@code").compactMap(\.stringValue)
        XCTAssertTrue(codes.allSatisfy { $0.count == 8 }, "Apple Event codes are four plus four characters")
        let plist = try XCTUnwrap(NSDictionary(contentsOf: repositoryURL("Resources/Info.plist")))
        XCTAssertEqual(plist["OSAScriptingDefinition"] as? String, "iCloudy.sdef")
        XCTAssertEqual(plist["NSAppleScriptEnabled"] as? Bool, true)
    }
}
