import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// One horizontal margin for every block of the detail column, so titles, banners, rows and the footer share an edge.
enum Layout {
    static let margin: CGFloat = 22
    static let sidebarOuter: CGFloat = 10
    static let sidebarInner: CGFloat = 12
    /// Difference between a Table's built-in cell inset and `margin`, measured on screen.
    static let tableCorrection: CGFloat = 4
    static let footerHeight: CGFloat = 38
    /// One height for everything the eye reads as a button in this window: las dos pestañas de la barra lateral, la
    /// fila de colecciones, las migas y el campo de filtro. macOS dibuja sus controles más bajos que el resto de
    /// esta ventana, así que los suyos van en tamaño grande y los dibujados a mano se ajustan a la misma cifra.
    static let controlHeight: CGFloat = 28
    /// Width of the transfers drawer on the right.
    static let transferDrawer: CGFloat = 360
}

/// A hairline between two groups of toolbar buttons, so a row of nine icons reads as four errands instead of one
/// long strip. Drawn by hand rather than with `Divider()`: inside a toolbar the system rule takes the full height
/// of the bar and looks like the window has been split in two.
struct ToolbarSeparator: View {
    static let height: CGFloat = 16
    var body: some View {
        Rectangle().fill(.quaternary)
            .frame(width: 1, height: Self.height)
            .padding(.horizontal, 3)
            .accessibilityHidden(true)
    }
}
