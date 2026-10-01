import SwiftUI
import AppKit

extension ExplorerView {
    /// The file list of the active tab. Each tab gets a list of its own, so switching does not carry one tab's
    /// scroll position over to another, and on coming back the list scrolls to what the tab had selected.
    var tabFileBrowser: some View {
        ScrollViewReader { proxy in
            fileBrowser
                .onAppear { revealSelection(proxy) }
                // After a relaunch the selection comes back before the listing does.
                .onChange(of: model.visibleFiles.isEmpty) { _, empty in if !empty { revealSelection(proxy) } }
        }
        .id(model.workspace.current.id)
    }

    private func revealSelection(_ proxy: ScrollViewProxy) {
        guard let first = model.visibleFiles.first(where: { selected.contains($0.id) }) else { return }
        proxy.scrollTo(first.id, anchor: .center)
    }
}
