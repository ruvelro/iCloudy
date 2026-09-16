import AppKit
import XCTest
@testable import iCloudy

@MainActor
final class WindowChromeTests: XCTestCase {
    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                 styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    }

    func testChromeOnlyChangesTheHostingWindow() {
        _ = NSApplication.shared
        let explorer = makeWindow()
        let settings = makeWindow()
        let settingsTransparency = settings.titlebarAppearsTransparent
        let settingsSeparator = settings.titlebarSeparatorStyle
        explorer.contentView = ExplorerWindowChrome.WindowAnchor()

        XCTAssertTrue(explorer.titlebarAppearsTransparent)
        XCTAssertEqual(explorer.titlebarSeparatorStyle, .none)
        XCTAssertEqual(settings.titlebarAppearsTransparent, settingsTransparency)
        XCTAssertEqual(settings.titlebarSeparatorStyle, settingsSeparator)
    }

    func testChromeIsAppliedWhenTheViewMovesToAnotherWindow() {
        _ = NSApplication.shared
        let anchor = ExplorerWindowChrome.WindowAnchor()
        let first = makeWindow()
        first.contentView = anchor
        first.contentView = nil
        let reopened = makeWindow()
        reopened.contentView = anchor

        XCTAssertTrue(reopened.titlebarAppearsTransparent)
        XCTAssertEqual(reopened.titlebarSeparatorStyle, .none)
    }
}
