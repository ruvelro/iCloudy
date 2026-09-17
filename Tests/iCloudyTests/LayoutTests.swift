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
