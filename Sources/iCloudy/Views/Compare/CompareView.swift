import SwiftUI
import AppKit

/// Two folders, side by side: what is only in one, what is the same, what differs, and what could not be told.
struct CompareView: View {
    @ObservedObject var center: CompareCenter
    @ObservedObject var model: AppModel
    @State private var selection: Set<ComparisonRow.ID> = []
    private var selectedRows: [ComparisonRow] { rows(selection) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            filters.padding(.horizontal, 18).padding(.vertical, 8)
            table
            Divider()
            footer.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .onChange(of: center.filter) { selection.removeAll() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                sideCard(.a, center.sideA) { center.sideA = $0 }
                Button { let a = center.sideA; center.sideA = center.sideB; center.sideB = a } label: { Image(systemName: "arrow.left.arrow.right") }
                    .help("Intercambiar A y B").accessibilityLabel("Intercambiar A y B")
                    .disabled(center.comparing).padding(.top, 22)
                sideCard(.b, center.sideB) { center.sideB = $0 }
            }
            HStack(spacing: 10) {
                Toggle("Calcular el hash de los archivos del Mac para compararlos con el de la nube", isOn: $center.hashLocally)
                    .disabled(center.comparing)
                Spacer()
                if center.comparing {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Detener") { center.cancelCompare() }
                } else {
                    Button("Comparar") { selection.removeAll(); center.startCompare() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(center.sideA == nil || center.sideB == nil)
                }
            }
        }
    }

    private func sideCard(_ side: ComparisonSide, _ location: FolderLocation?, set: @escaping (FolderLocation) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: side == .a ? "A" : "B").font(.title3.weight(.semibold))
                Spacer()
                FolderLocationMenu(model: model, title: "Elegir…", onPick: set).disabled(center.comparing)
            }
            if let location {
                HStack(spacing: 8) {
                    FolderLocationIcon(model: model, location: location)
                    Text(center.title(of: location)).lineLimit(1).truncationMode(.middle).help(center.title(of: location))
                }
            } else {
                Text("Elige una carpeta de una cuenta o del Mac.").foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private var progressText: String {
        let state = center.compareProgress
        let counts = L("\(state.folders) carpetas · \(state.items) elementos · \(state.hashed) archivos leídos")
        return state.current.isEmpty ? counts : counts + " · " + state.current
    }

    // MARK: - Filters and table

    private var filters: some View {
        HStack(spacing: 6) {
            chip(nil, title: L("Todo"), symbol: "list.bullet", count: center.result.total)
            ForEach(ComparisonGroup.allCases) { group in chip(group, title: group.title, symbol: group.symbol, count: center.result.count(group)) }
            Spacer()
        }
    }

    private func chip(_ group: ComparisonGroup?, title: String, symbol: String, count: Int) -> some View {
        let chosen = center.filter == group
        return Button { center.filter = group } label: {
            Label(title + " · " + count.formatted(), systemImage: symbol)
        }
        .buttonStyle(.bordered).tint(chosen ? .accentColor : nil)
        .fontWeight(chosen ? .semibold : .regular)
    }

    private var table: some View {
        Table(center.visibleRows, selection: $selection) {
            TableColumn("Ruta") { row in
                HStack(spacing: 6) {
                    Image(systemName: (row.a ?? row.b)?.isFolder == true ? "folder" : "doc").foregroundStyle(.secondary)
                    Text(row.path).lineLimit(1).truncationMode(.middle).help(row.path)
                    if row.caseDiffers {
                        Image(systemName: "textformat").foregroundStyle(.orange)
                            .help(Text("Los nombres solo difieren en mayúsculas: «\(row.a?.name ?? "")» y «\(row.b?.name ?? "")»."))
                    }
                }
            }.width(min: 200, ideal: 300)
            TableColumn("A") { row in Text(describe(row.a)).foregroundStyle(.secondary) }.width(min: 110, ideal: 150)
            TableColumn("B") { row in Text(describe(row.b)).foregroundStyle(.secondary) }.width(min: 110, ideal: 150)
            TableColumn("Estado") { row in
                Label(row.status.title, systemImage: row.status.group.symbol).foregroundStyle(tint(row.status.group)).lineLimit(1)
                    .help(row.status.title)
            }.width(min: 200, ideal: 340)
        }
        .contextMenu(forSelectionType: ComparisonRow.ID.self) { ids in
            actions(rows(ids))
        } primaryAction: { ids in
            guard let row = rows(ids).first, let compared = center.compared else { return }
            if let a = row.a, center.canPreview(a) { center.preview(a, in: compared.a) }
            else if let b = row.b, center.canPreview(b) { center.preview(b, in: compared.b) }
        }
        .overlay {
            if center.visibleRows.isEmpty, !center.comparing {
                if center.compared == nil {
                    ContentUnavailableView("Elige dos carpetas y pulsa Comparar", systemImage: "rectangle.split.2x1",
                                           description: Text("Pueden ser de dos cuentas distintas, de la misma, o una del Mac y otra de una nube. No se borra nada: solo se compara, y copiar es siempre una acción tuya."))
                } else if center.result.total == 0 {
                    ContentUnavailableView("Las dos carpetas están vacías", systemImage: "folder")
                } else {
                    ContentUnavailableView("Nada en este grupo", systemImage: "line.3.horizontal.decrease.circle")
                }
            }
        }
    }

    @ViewBuilder private func actions(_ rows: [ComparisonRow]) -> some View {
        let toB = center.copyable(rows, from: .a), toA = center.copyable(rows, from: .b)
        Button("Copiar de A a B (\(toB.count))") { center.copy(rows, from: .a) }.disabled(toB.isEmpty)
        Button("Copiar de B a A (\(toA.count))") { center.copy(rows, from: .b) }.disabled(toA.isEmpty)
        if rows.count == 1, let row = rows.first, let compared = center.compared {
            Divider()
            if let a = row.a {
                Button("Mostrar en A") { center.reveal(a, parent: row.parentA, in: compared.a) }
                if center.canPreview(a) { Button("Vista previa de A") { center.preview(a, in: compared.a) } }
            }
            if let b = row.b {
                Button("Mostrar en B") { center.reveal(b, parent: row.parentB, in: compared.b) }
                if center.canPreview(b) { Button("Vista previa de B") { center.preview(b, in: compared.b) } }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let problem = center.compareProblem { Text(problem).foregroundStyle(.red) }
                if let message = center.compareMessage { Text(message).foregroundStyle(.secondary) }
                if center.result.googleDocuments > 0 {
                    Text("\(center.result.googleDocuments) documentos de Google no tienen tamaño ni hash: se listan, pero nunca se dan por idénticos.")
                        .foregroundStyle(.secondary)
                }
                if center.result.omitted > 0 {
                    Text("\(center.result.omitted) filas cuentan en los totales pero no se muestran, para no agotar la memoria.")
                        .foregroundStyle(.secondary)
                }
                if let compared = center.compared, center.result.total > 0 {
                    Text("A: \(center.title(of: compared.a)) · B: \(center.title(of: compared.b))").foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Copiar de A a B") { center.copy(selectedRows, from: .a) }
                .disabled(center.copyable(selectedRows, from: .a).isEmpty)
                .help("Copia la selección a la carpeta correspondiente de B. Nunca se borra nada.")
            Button("Copiar de B a A") { center.copy(selectedRows, from: .b) }
                .disabled(center.copyable(selectedRows, from: .b).isEmpty)
                .help("Copia la selección a la carpeta correspondiente de A. Nunca se borra nada.")
        }
    }

    // MARK: - Helpers

    private func rows(_ ids: Set<ComparisonRow.ID>) -> [ComparisonRow] { center.visibleRows.filter { ids.contains($0.id) } }

    private func describe(_ entry: InventoryEntry?) -> String {
        guard let entry else { return "—" }
        if entry.isFolder { return L("Carpeta") }
        if entry.isGoogleDocument { return L("Documento de Google") }
        let size = entry.size.map(byteText) ?? "—"
        guard let date = entry.modified else { return size }
        return size + " · " + date.formatted(date: .abbreviated, time: .shortened)
    }

    private func tint(_ group: ComparisonGroup) -> Color {
        switch group {
        case .onlyInA, .onlyInB: return .blue
        case .different: return .orange
        case .unconfirmed: return .secondary
        case .identical: return .green
        }
    }
}
