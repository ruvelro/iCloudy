import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

extension ExplorerView {
    /// Configuración | recargar, subir, crear, descargar, ver | modo de lista | transferencias. The rules are what
    /// make those four groups visible; without them the toolbar was one undifferentiated row of icons.
    @ViewBuilder var explorerActions: some View {
        Group {
            ToolbarSeparator()
            Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Actualizar carpeta")
                .accessibilityLabel("Actualizar carpeta").keyboardShortcut("r", modifiers: .command)
                .disabled(model.account == nil || model.loading)
            Button { Task { await model.pickUpload() } } label: { Label("Subir", systemImage: "square.and.arrow.up") }.disabled(!model.canWrite)
            Button { model.promptName() } label: { Label("Nueva carpeta", systemImage: "folder.badge.plus") }.disabled(!model.canWrite)
            Button { Task { await model.saveMany(model.selection(selected)) } } label: { Label("Descargar selección", systemImage: "square.and.arrow.down") }.disabled(selected.isEmpty)
            Button { previewSelection() } label: { Image(systemName: "eye") }.help("Vista previa (Espacio)")
                .accessibilityLabel("Vista previa").disabled(selected.count != 1)
            ToolbarSeparator()
            Group {
                Picker("Vista", selection: $model.viewMode) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                }.pickerStyle(.segmented).frame(width: 80)
                // The sort used to live down in the header, beside the breadcrumbs. It answers the same question as
                // the two buttons on its left — how this list is drawn — so it now sits in the same group.
                Menu {
                    Picker("Orden", selection: $model.sortMode) {
                        Label("Nombre", systemImage: "textformat").tag("name")
                        Label("Más recientes", systemImage: "clock").tag("date")
                        Label("Mayor tamaño", systemImage: "arrow.up.arrow.down").tag("size")
                    }.pickerStyle(.inline).labelsHidden()
                } label: { Image(systemName: "arrow.up.arrow.down") }
                .accessibilityLabel("Ordenar la lista")
                    .help("Ordenar la lista")
            }
            ToolbarSeparator()
            // Personalizar and Desconectar used to hang off an ⋯ menu here. They belong to a cloud, not to the
            // window, so they now live where the cloud itself is: the right-click menu of its row in the sidebar.
            Button { withAnimation(.easeInOut(duration: 0.18)) { showTransfers.toggle() } } label: {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .symbolVariant(model.transfers.isEmpty ? .none : .fill)
            }.help(showTransfers ? "Ocultar transferencias" : "Mostrar transferencias")
        }
    }

    /// Selected items that are actually on screen: filtering the folder leaves ids selected that the list no longer
    /// shows, and a footer counting those would be counting something the user cannot see.
    var selectedCount: Int { model.visibleFiles.reduce(0) { selected.contains($1.id) ? $0 + 1 : $0 } }

    var trashTitle: String {
        guard let files = model.pendingTrash else { return "" }
        return files.count == 1 ? L("¿Enviar «\(files[0].name)» a la papelera?") : L("¿Enviar \(files.count) elementos a la papelera?")
    }

    var emptyTitle: String {
        if !model.search.isEmpty { return L("Sin resultados") }
        if model.path.isEmpty {
            switch model.collection {
            case .recent: return L("Todavía no hay elementos recientes")
            case .shared: return L("Nadie ha compartido nada contigo")
            case .files: break
            }
        }
        return L("Esta carpeta está vacía")
    }

    var emptyDescription: String {
        model.canWrite ? L("Arrastra archivos o carpetas para subirlos aquí.") : L("Esta lista la calcula el proveedor y no admite subidas.")
    }

    func previewSelection() {
        guard selected.count == 1, let file = model.selection(selected).first else { return }
        model.showPreview(file)
    }

    @ViewBuilder func fileActions(_ file: CloudFile) -> some View {
        Button("Vista previa") { model.showPreview(file) }
        Divider()
        Button(model.isFavorite(file) ? L("Quitar de favoritos") : L("Añadir a favoritos")) { model.toggleFavorite(file) }
        Button("Renombrar…") { model.promptName(file) }
        Button("Mover a…") { model.requestRelocation([file], copy: false) }
        Button("Copiar a…") { model.requestRelocation([file], copy: true) }
            .disabled((file.isFolder && model.account?.cloud == .google) || model.account?.capabilities.copy == false)
        if model.accounts.count > 1 { Button("Enviar a otra nube…") { model.requestCrossCloud([file]) } }
        Divider()
        if file.isFolder {
            Button("Abrir carpeta") { model.navigate(file) }
            Button("Reflejar una carpeta local aquí…") { Task { await model.pickMirrorSource(for: file) } }
            Button("Descargar carpeta…") { Task { await model.save(file) } }
        } else if !file.isGoogleDocument {
            Button("Descargar…") { Task { await model.save(file) } }
        }
        if file.webURL != nil { Button("Abrir en navegador") { model.openBrowser(file) } }
        ForEach(file.exportOptions, id: \.ext) { option in
            Button("Exportar como \(option.title)…") { Task { await model.save(file, export: (option.mime, option.ext)) } }
        }
        if let copy = model.localStatus(file).copy {
            Divider()
            Button("Mostrar la copia de este Mac en el Finder") { model.revealLocalCopy(file) }
                .help(copy.path)
            Button("Olvidar la copia local") { model.forgetLocalCopy(file) }
                .help(L("Quita la marca de descargado. No borra el archivo del Mac."))
        }
        Divider()
        if file.webURL != nil { Button("Copiar enlace") { model.copyLink(file) } }
        if let account = model.account, account.capabilities.publicLinks {
            Button("Crear enlace público de solo lectura…") { model.pendingShare = (file, account) }
        }
        Divider()
        Button(model.account?.capabilities.reversibleTrash == false ? "Eliminar del servidor…" : "Enviar a la papelera…", role: .destructive) { model.requestTrash([file]) }
    }
}
