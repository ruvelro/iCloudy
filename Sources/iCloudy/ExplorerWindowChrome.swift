import AppKit
import SwiftUI

/// Uses the window's own background through the title bar: no separate opaque strip or bottom rule.
/// Installed only in the explorer, so Settings and preview windows retain their native appearance.
struct ExplorerWindowChrome: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowAnchor { WindowAnchor() }
    func updateNSView(_ nsView: WindowAnchor, context: Context) {}

    final class WindowAnchor: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarAppearsTransparent = true
            window?.titlebarSeparatorStyle = .none
        }
    }
}
