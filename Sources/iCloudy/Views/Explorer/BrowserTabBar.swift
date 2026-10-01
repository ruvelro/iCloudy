import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The tabs of one pane, the way the Finder draws them: only once there is more than one, each as wide as the others,
/// with its close button showing on hover. Dragging a tab onto another puts it there.
struct BrowserTabBar: View {
    @ObservedObject var model: AppModel
    let pane: Int
    @State private var dragging: BrowserState.ID?

    var body: some View {
        let tabs = model.workspace.panes[pane].tabs
        let active = model.workspace.panes[pane].activeTab
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                if index > 0 { Divider().padding(.vertical, 6) }
                BrowserTabChip(model: model, tab: tab, active: index == active)
                    .onDrag {
                        dragging = tab.id
                        return NSItemProvider(object: tab.id.uuidString as NSString)
                    }
                    .onDrop(of: [.text], delegate: TabReorder(target: tab.id, dragging: $dragging, model: model))
            }
            Divider().padding(.vertical, 6)
            Button { model.newTab(in: pane) } label: { Image(systemName: "plus").frame(width: 28, height: 26).contentShape(Rectangle()) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help("Nueva pestaña (⌘T)").accessibilityLabel("Nueva pestaña")
        }
        .frame(height: 30)
        .background(Color.primary.opacity(0.04))
    }
}

private struct BrowserTabChip: View {
    @ObservedObject var model: AppModel
    let tab: BrowserState
    let active: Bool
    @State private var hovering = false

    var body: some View {
        let title = model.tabTitle(tab)
        ZStack {
            HStack(spacing: 6) {
                if let account = model.accounts.first(where: { $0.id == tab.accountID }) {
                    AccountIcon(account: account, appearance: model.appearance(for: account), size: 14)
                }
                Text(title).lineLimit(1).truncationMode(.middle)
                if tab.loading { ProgressView().controlSize(.mini) }
            }.padding(.horizontal, 26)
            HStack {
                Button { model.closeTab(tab.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 16, height: 16)
                        .background(Circle().fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                }.buttonStyle(.plain).foregroundStyle(.secondary)
                    .opacity(hovering ? 1 : 0).help("Cerrar pestaña (⌘W)").accessibilityLabel("Cerrar pestaña")
                Spacer()
            }.padding(.leading, 6)
        }
        .font(.callout).foregroundStyle(active ? .primary : .secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(active ? Color(nsColor: .windowBackgroundColor) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.activateTab(tab.id) }
        // The middle button closes a tab, as in any browser.
        .overlay(MiddleClick { model.closeTab(tab.id) })
        .contextMenu {
            Button("Nueva pestaña") { model.activateTab(tab.id); model.newTab() }
            Divider()
            Button("Cerrar pestaña") { model.closeTab(tab.id) }
            Button("Cerrar las otras pestañas") { model.closeOtherTabs(than: tab.id) }
        }
        .help(title)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
    }
}

/// Moves the dragged tab as it passes over the others, so the bar shows where it will land before it is dropped.
private struct TabReorder: DropDelegate {
    let target: BrowserState.ID
    @Binding var dragging: BrowserState.ID?
    let model: AppModel

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        withAnimation(.easeInOut(duration: 0.15)) { model.moveTab(dragging, to: target) }
    }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
}

/// Catches the middle mouse button and lets every other click through to what is underneath. SwiftUI has no gesture
/// for that button, and a view on top that took the ordinary clicks too would break selection and double-clicks.
struct MiddleClick: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> Catcher { Catcher(action: action) }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }

    final class Catcher: NSView {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, [.otherMouseDown, .otherMouseUp].contains(event.type) else { return nil }
            return super.hitTest(point)
        }
        override func otherMouseDown(with event: NSEvent) {
            if event.buttonNumber == 2 { action() } else { super.otherMouseDown(with: event) }
        }
    }
}

/// The explorer's own window, so ⌘W knows whether it is closing a tab or some other window that has the focus.
struct ExplorerWindowReader: NSViewRepresentable {
    @MainActor static weak var window: NSWindow?

    func makeNSView(context: Context) -> Reader { Reader() }
    func updateNSView(_ nsView: Reader, context: Context) {}

    final class Reader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { ExplorerWindowReader.window = window }
        }
    }
}
