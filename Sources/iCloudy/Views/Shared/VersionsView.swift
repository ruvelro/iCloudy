import SwiftUI

/// The remote versions of one file, newest first, and what can be done with each: look at it, keep a copy, make it
/// current again or delete it. Every change goes to the provider and the list is read back afterwards, as in the
/// sharing sheet; nothing here is kept locally.
struct VersionsView: View {
    @ObservedObject var model: AppModel
    let request: VersionsRequest
    @Environment(\.dismiss) private var dismiss
    @State private var versions: [FileVersion] = []
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var pendingRestore: FileVersion?
    @State private var pendingDelete: FileVersion?

    private var account: Account { request.account }
    private var file: CloudFile { request.file }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FileIcon(file: file)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Versiones de «\(file.name)»").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(model.accountTitle(account) + " · " + account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loading || working { ProgressView().controlSize(.small) }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if versions.isEmpty && !loading && problem == nil {
                    Text("El proveedor no guarda versiones anteriores de este archivo.").foregroundStyle(.secondary)
                }
                ForEach(versions) { version in row(version) }
            }.frame(minHeight: 180, maxHeight: 320)
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Actualizar la lista de versiones").accessibilityLabel("Actualizar la lista de versiones").disabled(loading || working)
                Spacer()
                Button("Cerrar") { model.versionHistory = nil; dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 600)
        .task { await load() }
        .confirmationDialog("¿Restaurar esta versión?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } }), titleVisibility: .visible, presenting: pendingRestore) { version in
            Button("Restaurar") { Task { await restore(version) } }
            Button("Cancelar", role: .cancel) { pendingRestore = nil }
        } message: { version in
            Text("«\(file.name)» volverá a tener el contenido del \(date(version)). Lo que tiene ahora se conserva en \(account.cloud.title) como una versión más.")
        }
        .confirmationDialog("¿Eliminar esta versión?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible, presenting: pendingDelete) { version in
            Button("Eliminar versión", role: .destructive) { Task { await delete(version) } }
            Button("Cancelar", role: .cancel) { pendingDelete = nil }
        } message: { version in
            Text("La versión del \(date(version)) se borra de \(account.cloud.title). El archivo y sus demás versiones no cambian.")
        }
    }

    @ViewBuilder private func row(_ version: FileVersion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: version.isCurrent ? "checkmark.circle.fill" : "clock.arrow.circlepath")
                .foregroundStyle(version.isCurrent ? Color.accentColor : .secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(date(version)).lineLimit(1)
                    if version.isCurrent {
                        Text("Actual").font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    if version.keepForever { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary).help("Google Drive la conserva para siempre") }
                }
                if !details(version).isEmpty {
                    Text(details(version)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Button { show(version) } label: { Image(systemName: "eye") }
                .buttonStyle(.plain).help("Vista previa de esta versión").accessibilityLabel("Vista previa de esta versión")
                .disabled(PreviewKind.forFile(file) == nil)
            download(version)
            Button { pendingRestore = version } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .buttonStyle(.plain).help(account.versionLimitation(.restore, version: version, of: file) ?? L("Restaurar esta versión"))
                .accessibilityLabel("Restaurar esta versión")
                .disabled(working || account.versionLimitation(.restore, version: version, of: file) != nil)
            if account.capabilities.deletesVersions {
                Button { pendingDelete = version } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).help(account.versionLimitation(.delete, version: version, of: file) ?? L("Eliminar esta versión"))
                    .accessibilityLabel("Eliminar esta versión")
                    .disabled(working || account.versionLimitation(.delete, version: version, of: file) != nil)
            }
        }.padding(.vertical, 2)
    }

    /// A Google document has no bytes of its own, so its versions are offered in the formats it exports to.
    @ViewBuilder private func download(_ version: FileVersion) -> some View {
        if file.isGoogleDocument {
            Menu {
                ForEach(file.exportOptions, id: \.ext) { option in
                    Button("Exportar como \(option.title)…") { Task { await model.saveVersion(version, of: request, export: (option.mime, option.ext)) } }
                }
            } label: { Image(systemName: "arrow.down.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help("Exportar esta versión").accessibilityLabel("Exportar esta versión")
                .disabled(file.exportOptions.isEmpty)
        } else {
            Button { Task { await model.saveVersion(version, of: request) } } label: { Image(systemName: "arrow.down.circle") }
                .buttonStyle(.plain).help("Descargar esta versión").accessibilityLabel("Descargar esta versión")
        }
    }

    private var explanation: String {
        switch account.cloud {
        case .google: return L("Google Drive guarda las versiones de un archivo 30 días o hasta 100, salvo las que se marcan para conservar. Restaurar sube el contenido de la versión como contenido nuevo.")
        case .dropbox: return L("Dropbox conserva las versiones durante un tiempo que depende del plan. Restaurar crea una versión nueva con ese contenido.")
        case .box: return L("Box guarda versiones según el plan de la cuenta. Restaurar convierte la versión elegida en la actual.")
        case .webdav: return L("Nextcloud guarda versiones y las va espaciando con el tiempo. Restaurar convierte la versión elegida en la actual.")
        default: return L("Restaurar una versión la convierte en la actual; la que había se conserva como una versión más.")
        }
    }
    private func date(_ version: FileVersion) -> String {
        version.modified?.formatted(date: .abbreviated, time: .shortened) ?? L("fecha desconocida")
    }
    private func details(_ version: FileVersion) -> String {
        var parts: [String] = []
        if let size = version.size { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let author = version.author { parts.append(author) }
        if let label = version.label { parts.append("«" + label + "»") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { versions = try await model.client(account).versions(of: file); problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func show(_ version: FileVersion) {
        do { try model.previewVersion(version, of: request) } catch { problem = error.localizedDescription }
    }
    private func restore(_ version: FileVersion) async {
        pendingRestore = nil
        guard !working else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.restoreVersion(version, of: request)
            notice = L("La versión del \(date(version)) es ahora la actual.")
            await load()
        } catch { problem = error.localizedDescription }
    }
    private func delete(_ version: FileVersion) async {
        pendingDelete = nil
        guard !working else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.deleteVersion(version, of: request)
            notice = L("Versión del \(date(version)) eliminada.")
            await load()
        } catch { problem = error.localizedDescription }
    }
}
