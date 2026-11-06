import SwiftUI
import AppKit

/// The window's animations, and none of them for whoever has asked the Mac to reduce motion.
///
/// Views read `accessibilityReduceMotion` from the environment where they can; actions run from a menu or a drop
/// delegate have no environment, so they ask the system here instead.
@MainActor
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// Rows moving to a new place, a drawer opening.
    static var quick: Animation? { reduced ? nil : .easeInOut(duration: 0.15) }
    static var drawer: Animation? { reduced ? nil : .easeInOut(duration: 0.18) }
    /// Scrolling the list to the item the arrows reached.
    static var scroll: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
}
