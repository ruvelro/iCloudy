import SwiftUI
import AppKit

extension ExplorerView {
    /// The file list of a pane's active tab. Each tab gets a list of its own, so switching does not carry one tab's
    /// scroll position over to another, and on coming back the list scrolls to what the tab had selected.
    func tabFileBrowser(_ pane: Int) -> some View {
        let tab = model.tab(inPane: pane)
        return ScrollViewReader { proxy in
            fileBrowser(pane)
                .onAppear { revealSelection(of: pane, proxy) }
                // After a relaunch the selection comes back before the listing does.
                .onChange(of: tab.visibleFiles.isEmpty) { _, empty in if !empty { revealSelection(of: pane, proxy) } }
        }
        .id(tab.id)
    }

    private func revealSelection(of pane: Int, _ proxy: ScrollViewProxy) {
        let tab = model.tab(inPane: pane)
        guard let first = tab.visibleFiles.first(where: { tab.selection.contains($0.id) }) else { return }
        proxy.scrollTo(first.id, anchor: .center)
    }
}
