import XCTest
import SwiftUI
import AppKit
@testable import iCloudy

/// Layout rules worth holding still. These are measured rather than argued about, because the last attempt at this
/// one looked right in the code and reserved no space at all on screen.
@MainActor
final class LayoutTests: XCTestCase {
    /// Measures the row the way the header actually uses it: stacked between siblings, with the header's spacing.
    /// Measuring the row on its own would miss the failure this test exists for, because a row that reserves nothing
    /// also swallows the stack's spacing around it.
    private func headerHeight(_ choices: [Collection]) -> CGFloat {
        let view = VStack(alignment: .leading, spacing: 12) {
            Text("Mis archivos").font(.system(size: 27, weight: .semibold))
            CollectionPicker(choices: choices, selection: .files) { _ in }
            Text("Inicio")
        }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    func testTheCollectionRowIsTheSameHeightForEveryProvider() {
        // Google Drive offers three collections, a WebDAV server offers one. If the row shrinks for the second, the
        // file list sits higher and changing account looks like the window moved.
        let one = headerHeight([.files])
        let two = headerHeight([.files, .recent])
        let three = headerHeight([.files, .recent, .shared])
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(one, three, accuracy: 0.5, "Una fila invisible sigue ocupando su sitio")
        XCTAssertEqual(one, two, accuracy: 0.5)

        // And it really is reserving something: a header without the row is shorter than one with it.
        let withoutRow = VStack(alignment: .leading, spacing: 12) {
            Text("Mis archivos").font(.system(size: 27, weight: .semibold))
            Text("Inicio")
        }.padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 14)
        let host = NSHostingView(rootView: withoutRow)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(one, host.fittingSize.height + 10, "Si no, la fila no estaría ocupando nada")
    }

    private func fittingHeight(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// La banda que hay bajo el título mezcla controles de macOS con cajas dibujadas a mano, y macOS dibuja los
    /// suyos más bajos. Si no miden lo mismo la fila se ve escalonada, que es justo la diferencia que no se aprecia
    /// leyendo el código.
    func testTheChromeUnderTheTitleIsAllOneHeight() {
        let collection = CollectionPicker(choices: [.files, .recent], selection: .files) { _ in }
        let crumb = Crumb(title: "Inicio", symbol: "folder", current: true) {}
        let field = ChromeField("Filtrar esta carpeta", symbol: "line.3.horizontal.decrease", text: .constant(""))
        let sort = Picker("", selection: .constant("name")) { Text("Nombre").tag("name") }
            .labelsHidden().controlSize(.large)
        let tabs = Picker("", selection: .constant(SidebarTab.clouds)) {
            ForEach(SidebarTab.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().controlSize(.large)
        for view in [AnyView(collection), AnyView(crumb), AnyView(field), AnyView(sort), AnyView(tabs)] {
            XCTAssertEqual(fittingHeight(view), Layout.controlHeight, accuracy: 0.5)
        }
    }

    private func fittingWidth(_ view: some View) -> CGFloat {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 120)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.width
    }

    /// The transfers drawer is a narrow column and its tab bar now carries four segments. A segmented picker never
    /// wraps: when the titles do not fit it shortens them to "En cu…", which is the kind of thing that only becomes
    /// obvious once the window is on screen.
    func testTheTransfersTabsAndFiltersFitTheDrawer() {
        let inner = Layout.transferDrawer - 28 // the panel's own horizontal padding
        let tabs = Picker("", selection: .constant(TransferTab.active)) {
            ForEach(TransferTab.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
        let width = fittingWidth(tabs)
        XCTAssertGreaterThan(width, 0)
        XCTAssertLessThanOrEqual(width, inner, "Las cuatro pestañas no caben en el cajón")

        // The error tab puts its filter and two icon buttons on one row, so the filter gets less than the full width.
        let filters = Picker("", selection: .constant(TransferErrorFilter.all)) {
            ForEach(TransferErrorFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
        XCTAssertLessThanOrEqual(fittingWidth(filters), inner - 50, "El filtro deja sitio a la papelera")
    }

    /// A hairline with no width is a separator nobody can see.
    /// Every tab reserves the same height for the row under the tabs — a count on one, a segmented filter on the
    /// next — so the list below does not shift when the tab changes. Reserving less than the tallest of them clips
    /// the filter instead.
    func testTheSectionBarReservesEnoughForItsTallestRow() {
        let filter = Picker("", selection: .constant(TransferErrorFilter.all)) {
            ForEach(TransferErrorFilter.allCases) { Text($0.title).tag($0) }
        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
        let broom = Button(action: {}) { Image(systemName: "trash") }.buttonStyle(.borderless)
        for view in [AnyView(filter), AnyView(broom), AnyView(Text("4 en curso").font(.caption2))] {
            XCTAssertLessThanOrEqual(NSHostingView(rootView: view).fittingSize.height, TransferPanel.sectionBarHeight)
        }
    }

    func testToolbarSeparatorReservesItsHairline() {
        let size = NSHostingView(rootView: ToolbarSeparator()).fittingSize
        XCTAssertGreaterThanOrEqual(size.width, 1)
        XCTAssertEqual(size.height, ToolbarSeparator.height, accuracy: 0.5)
    }

    func testEveryProviderOffersAtLeastOneCollection() {
        // The row is built from this list, so an empty one would collapse it for that provider alone.
        for cloud in Cloud.allCases {
            let account = Account(id: "x", cloud: cloud, name: "T", email: "t@ejemplo.com", clientID: "", clientSecret: nil)
            let choices = AppModel.collections(for: account)
            XCTAssertFalse(choices.isEmpty, "\(cloud) se quedaría sin fila")
            XCTAssertEqual(choices.first, .files, "\(cloud) empieza por sus archivos")
        }
    }
}
