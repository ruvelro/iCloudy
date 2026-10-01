import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// The row that picks between a provider's collections. It is a view of its own for one reason: its height has to
/// be the same for every provider, and that is worth a test rather than an assumption.
///
/// Providers differ in how many collections they have. Google Drive has three, a WebDAV server has one. Leaving the
/// row out for the ones with a single collection moved everything below it, so changing account looked like the
/// window had shifted. The picker is therefore always built, and merely invisible when there is nothing to choose:
/// opacity never affects layout, while omitting the row, or reserving a guessed height for it, does.
struct CollectionPicker: View {
    let choices: [Collection]
    let selection: Collection
    let select: (Collection) -> Void
    private var choosable: Bool { choices.count > 1 }

    var body: some View {
        Picker("Vista", selection: Binding(get: { selection }, set: { select($0) })) {
            ForEach(choices) { Label($0.title, systemImage: $0.icon).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().controlSize(.large).frame(maxWidth: 420)
        .opacity(choosable ? 1 : 0)
        .allowsHitTesting(choosable)
        .accessibilityHidden(!choosable)
    }
}
