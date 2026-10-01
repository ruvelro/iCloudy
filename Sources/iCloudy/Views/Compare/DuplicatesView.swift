import SwiftUI
import AppKit

/// Files with the same content across one or several folders, grouped, with the space each group wastes. Nothing is
/// marked for deletion until the person marks it, and every group has to keep at least one copy.
struct DuplicatesView: View {
    @ObservedObject var center: CompareCenter
    @ObservedObject var model: AppModel
    /// Past this many groups the list shows the largest ones only; the totals still cover them all.
    private static let groupLimit = 1_000

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 18).padding(.vertical, 12)
            Divider()
            if let report = center.report { summary(report).padding(.horizontal, 18).padding(.vertical, 8) }
            groups
            Divider()
            footer.padding(.horizontal, 18).padding(.vertical, 10)
        }
        .confirmationDialog(trashTitle, isPresented: $center.confirmingTrash, titleVisibility: .visible) {
            Button(center.permanentDeletions.isEmpty ? L("Enviar a la papelera") : L("Eliminar"), role: .destructive) {
                Task { await center.trashMarked() }
            }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(trashMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Dónde buscar").font(.headline)
                Spacer()
                FolderLocationMenu(model: model, title: "Añadir carpeta…") { location in
                    if !center.roots.contains(where: { $0.isSame(as: location) }) { center.roots.append(location) }
                }.disabled(center.scanning)
            }
            if center.roots.isEmpty {
                Text("Añade una o varias carpetas, de la misma cuenta o de varias, o del Mac.").foregroundStyle(.secondary)
            }
            ForEach(center.roots) { root in
                HStack(spacing: 8) {
                    FolderLocationIcon(model: model, location: root)
                    Text(center.title(of: root)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { center.roots.removeAll { $0.id == root.id } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless).foregroundStyle(.secondary).disabled(center.scanning)
                        .help("Quitar de la búsqueda").accessibilityLabel("Quitar de la búsqueda")
                }
            }
            HStack(spacing: 10) {
                Toggle("Calcular el hash de los archivos del Mac que tengan el mismo tamaño que otro", isOn: $center.hashLocally)
                    .disabled(center.scanning)
                Spacer()
                if center.scanning {
                    ProgressView().controlSize(.small)
                    Text(progressText).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Detener") { center.cancelScan() }
                } else {
                    Button("Buscar duplicados") { center.startScan() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(center.roots.isEmpty)
                }
            }
        }
    }

    private var progressText: String {
        let state = center.scanProgress
        var text = state.toHash > 0 ? L("Calculando hashes: \(state.hashed) de \(state.toHash)") : L("\(state.folders) carpetas · \(state.files) archivos")
        if !state.current.isEmpty { text += " · " + state.current }
        return text
    }

    // MARK: - Results

    private func summary(_ report: DuplicateReport) -> some View {
        let confirmed = report.groups.filter(\.isConfirmed).count, possible = report.groups.count - confirmed
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(confirmed) grupos con el mismo contenido · \(byteText(report.wasted)) se pueden liberar").font(.headline)
            if possible > 0 {
                Text("\(possible) posibles duplicados, con el mismo nombre y tamaño pero sin hash que lo confirme · \(byteText(report.possibleWasted))")
            }
            Group {
                if report.googleDocuments > 0 { Text("\(report.googleDocuments) documentos de Google no tienen tamaño ni hash y quedan fuera de la búsqueda.") }
                if report.emptyFiles > 0 { Text("\(report.emptyFiles) archivos vacíos no se cuentan: todos son iguales entre sí.") }
                if report.unsized > 0 { Text("\(report.unsized) archivos sin tamaño conocido quedan fuera.") }
                if report.unreadable > 0 { Text("\(report.unreadable) archivos del Mac no se pudieron leer para calcular su hash.") }
                if report.truncated { Text("La búsqueda se detuvo al llegar al límite de archivos, para no agotar la memoria. Busca en carpetas más pequeñas para ver el resto.").foregroundStyle(.orange) }
                if report.groups.count > Self.groupLimit { Text("Se muestran los \(Self.groupLimit) grupos que más espacio ocupan.") }
            }.foregroundStyle(.secondary)
        }
        .font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    private var groups: some View {
        List {
            ForEach(Array((center.report?.groups ?? []).prefix(Self.groupLimit))) { group in
                Section {
                    ForEach(group.members) { member in row(member) }
                } header: {
                    groupHeader(group)
                }
            }
        }
        .overlay {
            if !center.scanning, center.report?.groups.isEmpty != false {
                if center.report == nil {
                    ContentUnavailableView("Busca archivos repetidos", systemImage: "doc.on.doc",
                                           description: Text("Se agrupan los archivos con el mismo hash, también entre cuentas distintas. Tú eliges qué copias van a la papelera."))
                } else {
                    ContentUnavailableView("No hay duplicados", systemImage: "checkmark.circle")
                }
            }
        }
    }

    private func groupHeader(_ group: DuplicateGroup) -> some View {
        HStack(spacing: 8) {
            switch group.tier {
            case .content(let algorithms):
                let title = L("Mismo contenido · \(algorithms.map(\.title).joined(separator: ", "))")
                Label(title, systemImage: "checkmark.seal")
                    .foregroundStyle(.green)
            case .nameAndSize:
                Label("Posible duplicado · mismo nombre y tamaño, sin hash que lo confirme", systemImage: "questionmark.diamond")
                    .foregroundStyle(.orange)
            }
            Spacer()
            Text("\(group.members.count) copias de \(byteText(group.size)) · \(byteText(group.wasted)) de sobra").foregroundStyle(.secondary)
        }
    }

    private func row(_ member: DuplicateCandidate) -> some View {
        let location = center.location(of: member)
        return HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { center.marked.contains(member.id) },
                                 set: { if $0 { center.marked.insert(member.id) } else { center.marked.remove(member.id) } })) { EmptyView() }
                .toggleStyle(.checkbox).labelsHidden().disabled(center.trashing)
            if let location { FolderLocationIcon(model: model, location: location, size: 18) }
            VStack(alignment: .leading, spacing: 1) {
                Text(member.path).lineLimit(1).truncationMode(.middle)
                if let location { Text(center.title(of: location)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer()
            Text(member.entry.modified?.formatted(date: .abbreviated, time: .shortened) ?? "—").font(.caption).foregroundStyle(.secondary)
        }
        .contextMenu {
            if let location {
                Button("Mostrar en su carpeta") { center.reveal(member.entry, parent: member.parent, in: location) }
                Button("Vista previa") { center.preview(member.entry, in: location) }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let problem = center.scanProblem { Text(problem).foregroundStyle(.red) }
                if let message = center.scanMessage { Text(message).foregroundStyle(.secondary) }
                if !center.marked.isEmpty, !center.marksLeaveACopy {
                    Text("Has marcado todas las copias de algún grupo. Deja al menos una sin marcar.").foregroundStyle(.orange)
                } else if !center.marked.isEmpty {
                    Text("\(center.marked.count) marcados · \(byteText(center.markedBytes))").foregroundStyle(.secondary)
                }
            }
            .font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Marcar copias sobrantes") { center.markSuggested() }
                .help("En cada grupo con el mismo contenido marca todas las copias menos la más antigua. Los posibles duplicados no se marcan.")
                .disabled(center.report?.groups.contains(where: \.isConfirmed) != true || center.trashing)
            Button("Desmarcar todo") { center.marked.removeAll() }.disabled(center.marked.isEmpty || center.trashing)
            Button(center.permanentDeletions.isEmpty ? L("Enviar a la papelera…") : L("Eliminar…"), role: .destructive) { center.confirmingTrash = true }
                .disabled(!center.canTrash)
        }
    }

    private var trashTitle: String {
        let count = center.marked.count
        return center.permanentDeletions.isEmpty ? L("¿Enviar \(count) archivos a la papelera?") : L("¿Eliminar \(count) archivos?")
    }

    private var trashMessage: String {
        var text = L("Se liberan \(byteText(center.markedBytes)). Cada archivo va a la papelera de su nube o del Mac, y en cada grupo queda al menos una copia.")
        let permanent = center.permanentDeletions
        if !permanent.isEmpty {
            text += "\n\n" + L("En \(permanent.joined(separator: ", ")) no hay papelera: lo que hayas marcado allí se borra de forma definitiva y nadie podrá deshacerlo.")
        }
        return text
    }
}
