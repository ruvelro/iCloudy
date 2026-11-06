import AppKit
import SwiftUI
import XCTest
@testable import iCloudy

/// The explorer's 0.9 views, rendered off screen like the rest of ViewRenderingTests and read back through the
/// accessibility tree. Off screen, AppKit exposes the controls it backs (text fields, segmented pickers, the
/// toolbar) and the content of scroll views, but not every plain SwiftUI button; the checks stick to what it shows.
extension ViewRenderingTests {
    func testTheFilterFieldSaysWhatItIsAndWhatItHolds() async throws {
        let rendered = try await render(ChromeField("Filtrar esta carpeta", text: .constant("informe")), size: NSSize(width: 300, height: 40))
        assertOffers([L("Filtrar esta carpeta"), "informe"], in: rendered)
    }

    func testThePathBarIsAFieldWithALabelAndAHint() async throws {
        model.ui.editingPath = 0
        let rendered = try await render(ExplorerView(model: model)) { $0.contains(L("Ruta de la carpeta")) }
        assertOffers([L("Ruta de la carpeta"), L("Escribe una ruta y pulsa Intro para ir. Escape vuelve a las migas.")], in: rendered)
    }

    func testTheViewPickerOffersTheColumnView() async throws {
        let rendered = try await render(ExplorerView(model: model)) { $0.contains(L("Columnas")) }
        assertOffers([L("Lista"), L("Iconos"), L("Columnas"), L("Inspector")], in: rendered)
    }

    func testGridCellsCarryTheirStatusAsAValue() async throws {
        model.viewMode = "grid"
        let rendered = try await render(ExplorerView(model: model)) { $0.contains("Proyectos") && $0.contains(L("Carpeta")) }
        // Off screen only the first cell is sure to be realised: the folder, whose value says what it is.
        assertOffers(["Proyectos", L("Carpeta")], in: rendered)
    }

    func testTheInspectorShowsTheSelectionsFigures() async throws {
        try await wait(until: { self.model.files.contains { $0.name == "Bienvenido.txt" } })
        let welcome = try XCTUnwrap(model.files.first { $0.name == "Bienvenido.txt" })
        model.selectedIDs = [welcome.id]
        let address = model.accountTitle(Account.demo) + ":/Bienvenido.txt"
        let rendered = try await render(InspectorView(model: model), size: NSSize(width: 300, height: 600)) { $0.contains(address) }
        assertDrawn(rendered)
        // The figures are selectable text, which AppKit exposes off screen; their names are SwiftUI labels it does not.
        assertOffers(["Bienvenido.txt", L("Solo en la nube"), address], in: rendered)
    }

    func testGoToFolderExplainsTheAccountSyntaxOnItsField() async throws {
        let rendered = try await render(GoToFolderView(model: model), size: NSSize(width: 460, height: 300)) { !$0.isEmpty }
        assertOffers([L("Escribe la ruta desde el principio de la cuenta. Para otra cuenta, pon su nombre delante, como «Dropbox:/Fotos».")], in: rendered)
    }
}
