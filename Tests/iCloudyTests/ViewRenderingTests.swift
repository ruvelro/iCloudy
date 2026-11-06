import AppKit
import SwiftUI
import XCTest
@testable import iCloudy

/// Lightweight view tests: the main windows are laid out for real in an off-screen NSHostingView over the demo
/// account, drawn into a bitmap, and their accessibility tree is read back. No golden images: what is checked is that
/// each view renders without crashing, draws something, and still offers the controls VoiceOver users reach it by.
/// The helpers are internal so ExplorerAccessibilityTests can extend this class with the explorer's 0.9 views.
@MainActor
final class ViewRenderingTests: XCTestCase {
    var model: AppModel!
    private var windows: [NSWindow] = []

    override func setUp() async throws {
        _ = NSApplication.shared
        // SwiftUI builds its accessibility tree only once something asks for it, as VoiceOver does by setting this.
        NSApp.setValue(true, forKey: "accessibilityEnhancedUserInterface")
        model = AppModel()
        model.enableDemo()
        model.demo?.latency = .milliseconds(1)
        // Under test the model never reads the Keychain and stays "loading"; the window would show only that.
        model.loadingAccounts = false
        model.reloadVisible()
    }

    override func tearDown() async throws {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        model = nil
    }

    struct Rendered {
        let hosting: NSView
        let labels: [String]
        let bitmap: NSBitmapImageRep?
    }

    /// Lays `view` out in a window that is never shown, lets the main actor settle (the demo answers in a
    /// millisecond), draws it and collects every accessibility label and title below it.
    func render<V: View>(_ view: V, size: NSSize = NSSize(width: 1100, height: 760),
                                 until ready: (([String]) -> Bool)? = nil) async throws -> Rendered {
        let hosting = NSHostingView(rootView: view.defaultAppStorage(Prefs.defaults))
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        windows.append(window)
        window.alphaValue = 0.01   // on screen, so AppKit and SwiftUI treat it as visible, yet out of anybody's way
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        var labels: [String] = []
        let clock = ContinuousClock(), deadline = clock.now + .seconds(10)
        repeat {
            hosting.layoutSubtreeIfNeeded()
            await drainMainActor()
            try await Task.sleep(for: .milliseconds(20))   // the main run loop draws and answers meanwhile
            labels = Self.accessibilityText(of: window)
        } while !(ready?(labels) ?? !labels.isEmpty) && clock.now < deadline
        // SwiftUI draws into layers, which cacheDisplay(in:to:) does not always see; the layer tree is rendered instead.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        if let bitmap, let context = NSGraphicsContext(bitmapImageRep: bitmap), let layer = hosting.layer {
            layer.render(in: context.cgContext)
        }
        return Rendered(hosting: hosting, labels: labels, bitmap: bitmap)
    }

    /// From the window, so a toolbar SwiftUI puts in the title bar is included.
    static func accessibilityText(of root: NSWindow) -> [String] {
        var found: [String] = []
        var pending: [Any] = [root]
        var visited = 0
        while let next = pending.popLast(), visited < 20_000 {
            visited += 1
            guard let element = next as? NSAccessibilityProtocol else { continue }
            for text in [element.accessibilityLabel(), element.accessibilityTitle()] {
                if let text, !text.isEmpty { found.append(text) }
            }
            switch element.accessibilityValue() {
            case let value as String where !value.isEmpty: found.append(value)
            case let value as NSAttributedString where value.length > 0: found.append(value.string)
            default: break
            }
            if let text = (next as? NSTextField)?.stringValue, !text.isEmpty { found.append(text) }
            if let help = element.accessibilityHelp(), !help.isEmpty { found.append(help) }
            pending.append(contentsOf: element.accessibilityChildren() ?? [])
            // AppKit views SwiftUI hosts (lists, tables, text fields) are reached through the view tree as well.
            if let view = next as? NSView { pending.append(contentsOf: view.subviews) }
            if let window = next as? NSWindow, let content = window.contentView?.superview { pending.append(content) }
            if let table = next as? NSTableView {
                for row in 0..<min(table.numberOfRows, 200) {
                    for column in 0..<table.numberOfColumns {
                        if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) { pending.append(cell) }
                    }
                }
            }
        }
        return found
    }

    func assertDrawn(_ rendered: Rendered, file: StaticString = #filePath, line: UInt = #line) {
        guard let bitmap = rendered.bitmap else { return XCTFail("Nothing to draw into", file: file, line: line) }
        XCTAssertGreaterThan(bitmap.pixelsWide, 0, file: file, line: line)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 0, file: file, line: line)
        // Something other than a single flat colour was drawn: every pixel is looked at, so a line of text counts.
        var colours = Set<UInt32>()
        if let data = bitmap.bitmapData {
            let words = UnsafeRawPointer(data).bindMemory(to: UInt32.self, capacity: bitmap.bytesPerRow / 4 * bitmap.pixelsHigh)
            for index in 0..<(bitmap.bytesPerRow / 4 * bitmap.pixelsHigh) where colours.count < 2 { colours.insert(words[index]) }
        }
        XCTAssertGreaterThan(colours.count, 1, "The view drew nothing", file: file, line: line)
    }

    func assertOffers(_ expected: [String], in rendered: Rendered, file: StaticString = #filePath, line: UInt = #line) {
        for label in expected {
            XCTAssertTrue(rendered.labels.contains { $0 == label || $0.contains(label) },
                          "No accessibility element says «\(label)». Found: \(Array(Set(rendered.labels)).sorted().prefix(80))", file: file, line: line)
        }
    }

    // MARK: - The views

    func testTheExplorerRendersItsToolbarOverTheDemoFolder() async throws {
        let rendered = try await render(ExplorerView(model: model)) { $0.contains(L("Actualizar carpeta")) }
        assertDrawn(rendered)
        XCTAssertEqual(model.files.map(\.name).sorted(), try XCTUnwrap(model.demo).list("root").map(\.name).sorted(), "The demo folder was listed")
        assertOffers([L("Atrás"), L("Adelante"), L("Actualizar carpeta"), L("Nueva carpeta"), L("Subir"), L("Doble panel")], in: rendered)
    }

    func testTheGridNamesEveryItemForVoiceOver() async throws {
        model.viewMode = "grid"
        let rendered = try await render(ExplorerView(model: model)) { $0.contains("Proyectos") }
        assertDrawn(rendered)
        // The grid labels each cell with its name. Off screen, AppKit only exposes the cells it has realised, which
        // is not always all of them, so the first one is what is checked.
        assertOffers(["Proyectos"], in: rendered)
    }

    func testTheSidebarListsTheDemoAccount() async throws {
        let rendered = try await render(ExplorerView(model: model)) { $0.contains { $0.contains(Account.demo.name) } }
        assertOffers([Account.demo.name], in: rendered)
    }

    func testTheTransferPanelRendersAnEmptyQueueAndItsControls() async throws {
        let rendered = try await render(TransferPanel(model: model, queue: model.queue, history: model.history),
                                        size: NSSize(width: 420, height: 600))
        assertDrawn(rendered)
        assertOffers([L("En curso"), L("Finalizadas"), L("Historial")], in: rendered)
    }

    func testTheSettingsWindowRenders() async throws {
        let rendered = try await render(SettingsView(model: model), size: NSSize(width: 700, height: 560))
        assertDrawn(rendered)
        XCTAssertFalse(rendered.labels.isEmpty, "Settings exposes its controls to accessibility")
        assertOffers([L("Megabytes antes de preguntar")], in: rendered)
    }

    func testGlobalSearchRendersItsFieldAndTheWayBack() async throws {
        let rendered = try await render(GlobalSearchView(model: model, search: model.globalSearch, saved: model.savedSearches),
                                        size: NSSize(width: 800, height: 600))
        assertDrawn(rendered)
        assertOffers([L("Buscar en todas las nubes"), L("Volver al explorador")], in: rendered)
    }
}
