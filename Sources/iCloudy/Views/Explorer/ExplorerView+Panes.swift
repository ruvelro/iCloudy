import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension ExplorerView {
    /// One of the two panes: its tabs, its header and its list. The focused one carries the accent along its top
    /// edge. Rows dragged from the other pane land in this pane's folder.
    func paneColumn(_ pane: Int) -> some View {
        let focused = model.workspace.focusedPane == pane
        return VStack(spacing: 0) {
            if model.workspace.panes[pane].tabs.count > 1 {
                BrowserTabBar(model: model, pane: pane)
                Divider()
            }
            header(pane)
            Divider()
            paneBody(pane)
        }
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle().fill(focused ? Color.accentColor : Color.clear).frame(height: 2).allowsHitTesting(false)
        }
        .background(PaneFocusTracker { model.focusPane(pane) })
        .onDrop(of: [.iCloudyPaneItems], isTargeted: nil) { providers in
            guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.iCloudyPaneItems.identifier) }) else { return false }
            // Read now: by the time the data arrives the keys may have been let go.
            let modifiers = NSEvent.modifierFlags
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.iCloudyPaneItems.identifier) { data, _ in
                guard let data, let token = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in _ = model.dropOnPane(token, pane: pane, modifiers: modifiers) }
            }
            return true
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(pane == 0 ? "Panel izquierdo" : "Panel derecho")
    }

    /// "Copiar al otro panel" and "Mover al otro panel", while there are two.
    @ViewBuilder func otherPaneActions(_ files: [CloudFile]) -> some View {
        if let other = model.workspace.otherPane {
            Button("Copiar al otro panel") { model.sendToPane(files, from: model.workspace.focusedPane, to: other, move: false) }
            Button("Mover al otro panel") { model.sendToPane(files, from: model.workspace.focusedPane, to: other, move: true) }
        }
    }

    var paneMoveTitle: String {
        guard let request = model.pendingPaneMove else { return "" }
        let target = model.accountTitle(request.target)
        return request.files.count == 1 ? L("¿Mover «\(request.files[0].name)» a \(target)?") : L("¿Mover \(request.files.count) elementos a \(target)?")
    }

    func paneMoveMessage(_ request: PaneMoveRequest) -> String {
        let target = model.accountTitle(request.target), source = request.source.cloud.title
        return request.source.capabilities.reversibleTrash
            ? L("Se copia a \(target) y cada original va a la papelera de \(source) solo cuando su copia haya llegado completa y verificada. Si algo no se puede verificar o se omite, el original se queda donde está.")
            : L("Se copia a \(target) y cada original se elimina de \(source) de forma definitiva, porque no tiene papelera, solo cuando su copia haya llegado completa y verificada. Si algo no se puede verificar o se omite, el original se queda donde está.")
    }
}

extension View {
    /// Rows can be dragged to the other pane only while there is one. With a single pane they stay as they were, so
    /// dragging across the list still picks a run of rows.
    @ViewBuilder func paneDragSource(_ enabled: Bool, _ provider: @escaping () -> NSItemProvider) -> some View {
        if enabled { onDrag(provider) } else { self }
    }
}

/// Gives a pane the focus on any click inside it, before the click itself is handled: a context menu, a double-click
/// or a toolbar action that follows then works on the pane that was clicked. It never takes a click for itself.
struct PaneFocusTracker: NSViewRepresentable {
    let focus: () -> Void

    func makeNSView(context: Context) -> Tracker { Tracker(focus: focus) }
    func updateNSView(_ view: Tracker, context: Context) { view.focus = focus }
    static func dismantleNSView(_ view: Tracker, coordinator: ()) { view.stop() }

    final class Tracker: NSView {
        var focus: () -> Void
        private var monitor: Any?
        init(focus: @escaping () -> Void) { self.focus = focus; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                guard let self, let window = self.window, event.window === window else { return event }
                if self.bounds.contains(self.convert(event.locationInWindow, from: nil)) { self.focus() }
                return event
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

/// Tab, with two panes, moves the focus to the other one; in a text field it still moves between fields.
struct PaneKeyMonitor: NSViewRepresentable {
    let enabled: Bool
    let switchPanes: () -> Void

    func makeNSView(context: Context) -> Monitor { Monitor(enabled: enabled, switchPanes: switchPanes) }
    func updateNSView(_ view: Monitor, context: Context) { view.enabled = enabled; view.switchPanes = switchPanes }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }

    final class Monitor: NSView {
        var enabled: Bool
        var switchPanes: () -> Void
        private var monitor: Any?
        /// The Tab key, whatever the keyboard layout.
        static let tabKey: UInt16 = 48
        init(enabled: Bool, switchPanes: @escaping () -> Void) {
            self.enabled = enabled; self.switchPanes = switchPanes
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.window, event.window === window, event.keyCode == Self.tabKey,
                      event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(window.firstResponder is NSText) else { return event }
                self.switchPanes()
                return nil
            }
        }
        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
