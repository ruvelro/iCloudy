import SwiftUI
import AppKit

/// The column view: one column per folder from the top down to the open one, and the selected folder's contents
/// after it, as the Finder draws it. ← and → move between columns, ↑ and ↓ within the open one, Return opens.
struct ColumnBrowserView: View {
    let model: AppModel
    let pane: Int
    /// Opens a file (preview, download or the browser) the way a double-click in the list does.
    let open: (CloudFile) -> Void
    /// The folder → just entered, whose first item is selected as soon as its listing arrives.
    @State private var entering: String?
    static let columnWidth: CGFloat = 230

    var body: some View {
        let tab = model.tab(inPane: pane)
        let columns = model.columns(inPane: pane)
        ScrollViewReader { scroller in
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(columns) { column in
                        ColumnList(model: model, pane: pane, column: column, open: open)
                            .frame(width: Self.columnWidth)
                            .task(id: column.id) { await model.loadColumn(column, inPane: pane) }
                            .id(column.id)
                        Divider()
                    }
                    if let file = Self.selectedFile(tab) {
                        ColumnPreview(model: model, file: file, tab: tab).frame(width: Self.columnWidth + 40).id("preview")
                    }
                }
            }
            .onChange(of: columns.last?.id) { _, last in
                guard let last else { return }
                withAnimation(Motion.scroll) { scroller.scrollTo(Self.selectedFile(tab) == nil ? last : "preview", anchor: .trailing) }
            }
        }
        .onChange(of: tab.visibleFiles.first?.id) { _, first in
            guard let first, entering == tab.folderID, tab.selection.isEmpty else { return }
            entering = nil
            model.workspace.update(tab.id) { $0.selection = [first] }
        }
        .onMoveCommand { direction in
            switch direction {
            case .up: model.columnStep(-1, pane: pane)
            case .down: model.columnStep(1, pane: pane)
            case .left: model.columnLeft(pane: pane)
            case .right:
                if let folder = model.columnRight(pane: pane) {
                    entering = folder.id
                    if let first = model.tab(inPane: pane).visibleFiles.first {
                        entering = nil
                        model.workspace.update(model.tab(inPane: pane).id) { $0.selection = [first.id] }
                    }
                }
            @unknown default: break
            }
        }
        .onKeyPress(.return) {
            let chosen = AppModel.selected(tab.selection, among: tab.visibleFiles)
            guard chosen.count == 1, let file = chosen.first else { return .ignored }
            if file.isFolder { model.navigate(file) } else { open(file) }
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Vista en columnas")
    }

    /// A single file selected in the open folder gets a column of its own describing it.
    private static func selectedFile(_ tab: BrowserState) -> CloudFile? {
        let chosen = AppModel.selected(tab.selection, among: tab.visibleFiles)
        guard chosen.count == 1, let file = chosen.first, !file.isFolder else { return nil }
        return file
    }
}

/// One folder's items, in a column.
private struct ColumnList: View {
    let model: AppModel
    let pane: Int
    let column: BrowserColumn
    let open: (CloudFile) -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if let files = column.files {
                ScrollViewReader { scroller in
                    ScrollView(.vertical) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(files) { file in row(file) }
                        }.padding(4)
                    }
                    .onAppear { if let first = column.highlighted.first { scroller.scrollTo(first, anchor: .center) } }
                    .onChange(of: column.highlighted) { _, ids in
                        if let first = ids.first { withAnimation(Motion.scroll) { scroller.scrollTo(first) } }
                    }
                }
                .overlay {
                    if files.isEmpty {
                        Text(column.role == .current && model.tab(inPane: pane).loading ? L("Cargando…") : L("Vacía"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(column.role == .preview ? Color.primary.opacity(0.025) : .clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(columnTitle)
    }

    private var columnTitle: String {
        let tab = model.tab(inPane: pane)
        if column.level == 0 { return tab.collection == .files ? L("Inicio") : tab.collection.title }
        if column.role == .preview { return AppModel.selected(tab.selection, among: tab.visibleFiles).first?.name ?? "" }
        return tab.path.indices.contains(column.level - 1) ? tab.path[column.level - 1].name : ""
    }

    private func row(_ file: CloudFile) -> some View {
        let highlighted = column.highlighted.contains(file.id)
        // The open folder's selection is the one the keyboard moves; the folders above only say how it got there.
        let strong = highlighted && column.role == .current
        return HStack(spacing: 7) {
            FileIcon(file: file, size: 13)
            Text(file.name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if file.isFolder { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary).accessibilityHidden(true) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(strong ? Color.white : Color.primary)
        .background(strong ? Color.accentColor : (highlighted ? Color.primary.opacity(contrast == .increased ? 0.22 : 0.12) : .clear),
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if file.isFolder { model.columnClick(file, column: column, pane: pane); model.navigate(file) } else { open(file) }
        }
        .onTapGesture {
            model.columnClick(file, column: column, pane: pane, extend: NSEvent.modifierFlags.contains(.command))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(highlighted ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(file.isFolder ? L("Muestra su contenido en la columna siguiente") : L("Selecciona el archivo"))
        .id(file.id)
    }
}

/// The last column when a file is selected: its icon, its name and the figures that matter.
private struct ColumnPreview: View {
    let model: AppModel
    let file: CloudFile
    let tab: BrowserState

    var body: some View {
        VStack(spacing: 10) {
            ThumbnailIcon(file: file, account: model.account(of: tab), store: model.thumbnails, size: 64)
                .padding(.top, 30)
            Text(file.name).font(.headline).multilineTextAlignment(.center).lineLimit(4)
            Text(file.kindDescription).font(.caption).foregroundStyle(.secondary)
            Divider().padding(.horizontal, 20)
            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                GridRow {
                    Text("Tamaño").foregroundStyle(.secondary)
                    Text(file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "—")
                }
                GridRow {
                    Text("Modificado").foregroundStyle(.secondary)
                    Text(file.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                }
            }.font(.caption)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}
