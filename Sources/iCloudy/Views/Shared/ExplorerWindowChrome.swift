import AppKit
import SwiftUI

/// The translucent material behind the sidebar. A plain colour would flatten the window: an ordinary split view does
/// not bring the vibrancy that `NavigationSplitView` installs on its own.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

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
