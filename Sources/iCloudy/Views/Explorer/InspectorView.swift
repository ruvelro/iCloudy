import SwiftUI

/// The inspector (⌘I): everything iCloudy knows about the selection, and the few things to do with it.
struct InspectorView: View {
    let model: AppModel
    @State private var versions: Int?
    @State private var links: Int?

    var body: some View {
        let summary = model.inspectorSummary()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch summary.content {
                case .nothing:
                    ContentUnavailableView("Sin selección", systemImage: "info.circle",
                                           description: Text("Selecciona un archivo o una carpeta para ver su información."))
                        .padding(.top, 40)
                case .single(let item):
                    single(item)
                        .task(id: item.file.id + item.file.name) { await details(item) }
                case .many(let totals):
                    many(totals)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector")
    }

    private func details(_ item: InspectorSummary.Item) async {
        versions = nil; links = nil
        if item.hasVersions { versions = await model.versionCount(of: item.file, accountID: item.accountID) }
        if item.listsLinks { links = await model.publicLinkCount(of: item.file, accountID: item.accountID) }
    }

    @ViewBuilder private func single(_ item: InspectorSummary.Item) -> some View {
        let file = item.file
        HStack(alignment: .top, spacing: 10) {
            FileIcon(file: file, size: 30)
            Text(file.name).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        Divider()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 7) {
            row("Tipo", item.kind)
            if !file.isFolder {
                row("Tamaño", file.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L("Desconocido"))
            }
            row("Modificado", file.modified?.formatted(date: .long, time: .shortened) ?? L("Desconocido"))
            row("Cuenta", item.accountTitle)
            row("Ruta", item.address)
            if let checksum = item.checksum {
                row("Suma", checksum.value, monospaced: true)
                row("Algoritmo", checksum.algorithm.title)
            } else if !file.isFolder {
                row("Suma", L("El proveedor no lista ninguna"))
            }
            if !file.isFolder { row("En este Mac", item.local.label) }
            if let offline = item.offline { row("Sin conexión", offline.label) }
            if let editing = item.editing { row("Abierto", editing) }
            if item.hasVersions { row("Versiones", versions.map { "\($0)" } ?? "…") }
            if item.listsLinks {
                row("Enlaces públicos", links.map { $0 == 0 ? L("Ninguno") : "\($0)" } ?? "…")
            } else if file.webURL != nil {
                row("Enlace", L("Web del proveedor"))
            }
        }
        Divider()
        VStack(alignment: .leading, spacing: 6) {
            Button { model.copyPath(file) } label: { Label("Copiar ruta", systemImage: "doc.on.doc") }
            if file.webURL != nil {
                Button { model.copyLink(file) } label: { Label("Copiar enlace", systemImage: "link") }
            }
            if item.local.copy != nil {
                Button { model.revealLocalCopy(file) } label: { Label("Mostrar la copia de este Mac", systemImage: "folder") }
            }
            if !file.isFolder, model.openWithLimitation(file) == nil {
                Button { Task { await model.openWith(file) } } label: { Label("Abrir con la aplicación predeterminada", systemImage: "arrow.up.forward.app") }
            }
        }.buttonStyle(.link)
    }

    @ViewBuilder private func many(_ totals: InspectorSummary.Totals) -> some View {
        Text(L("\(totals.count) elementos")).font(.headline)
        Divider()
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 7) {
            row("Carpetas", "\(totals.folders)")
            row("Archivos", "\(totals.files)")
            row("Tamaño", ByteCountFormatter.string(fromByteCount: totals.bytes, countStyle: .file)
                + (totals.unknownSizes > 0 ? " " + L("(sin contar \(totals.unknownSizes) sin tamaño)") : ""))
        }
        Text("El tamaño de las carpetas no se suma: los proveedores no lo dan sin recorrerlas.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: LocalizedStringKey, _ value: String, monospaced: Bool = false) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .font(monospaced ? .callout.monospaced() : .callout)
        }
        .accessibilityElement(children: .combine)
    }
}
