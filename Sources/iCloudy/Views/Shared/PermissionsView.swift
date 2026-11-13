import SwiftUI

/// An item of an SFTP account whose permissions are being looked at.
struct PermissionsRequest: Identifiable {
    let id = UUID()
    let file: CloudFile
    let account: Account
}

/// chmod, with the nine boxes and the number, whichever the person thinks in.
struct PermissionsView: View {
    @Bindable var model: AppModel
    let request: PermissionsRequest
    @Environment(\.dismiss) private var dismiss
    @State private var mode: POSIXMode?
    @State private var original: POSIXMode?
    @State private var octal = ""
    @State private var recursive = false
    @State private var working = false
    @State private var problem: String?

    private func title(_ who: POSIXMode.Who) -> LocalizedStringKey {
        switch who { case .owner: return "Propietario"; case .group: return "Grupo"; case .others: return "Los demás" }
    }
    private func binding(_ what: POSIXMode.What, _ who: POSIXMode.Who) -> Binding<Bool> {
        Binding(get: { mode?.allows(what, who) ?? false },
                set: { allowed in mode?.set(what, who, allowed); octal = mode?.octal ?? octal })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FileIcon(file: request.file, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permisos").font(.title3.weight(.semibold))
                    Text(request.file.name).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if working || mode == nil && problem == nil { ProgressView().controlSize(.small) }
            }
            if mode != nil {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("")
                        Text("Leer").font(.caption).foregroundStyle(.secondary)
                        Text("Escribir").font(.caption).foregroundStyle(.secondary)
                        Text(request.file.isFolder ? "Entrar" : "Ejecutar").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(POSIXMode.Who.allCases, id: \.self) { who in
                        GridRow {
                            Text(title(who))
                            Toggle("", isOn: binding(.read, who)).labelsHidden().accessibilityLabel(Text("Leer"))
                            Toggle("", isOn: binding(.write, who)).labelsHidden().accessibilityLabel(Text("Escribir"))
                            Toggle("", isOn: binding(.execute, who)).labelsHidden().accessibilityLabel(Text("Ejecutar"))
                        }
                    }
                }
                HStack {
                    TextField("755", text: $octal).frame(width: 70).textFieldStyle(.roundedBorder).font(.body.monospaced())
                        .onChange(of: octal) { _, text in if let parsed = POSIXMode(octal: text) { mode = parsed } }
                    Text(verbatim: mode?.symbolic ?? "").font(.body.monospaced()).foregroundStyle(.secondary)
                }
                if POSIXMode(octal: octal) == nil {
                    Text("Escribe los permisos en octal, con tres o cuatro cifras: 644, 755, 2775…").font(.caption).foregroundStyle(.orange)
                }
                if request.file.isFolder {
                    Toggle("Aplicar también a todo lo que contiene", isOn: $recursive)
                    Text("Las carpetas de dentro reciben los mismos permisos. Los archivos también, salvo el de ejecución, que cada uno conserva como lo tenía.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Cancelar") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Aplicar") { Task { await apply() } }.keyboardShortcut(.defaultAction)
                    .disabled(working || mode == nil || POSIXMode(octal: octal) == nil || (mode == original && !recursive))
            }
        }
        .padding(24).frame(width: 420)
        .task { await load() }
    }

    private func provider() throws -> SFTPProvider {
        guard let provider = try model.client(request.account).provider as? SFTPProvider else {
            throw CloudError.message(L("Solo las cuentas SFTP permiten cambiar permisos."))
        }
        return provider
    }
    private func load() async {
        do {
            let current = try await provider().sftpPermissions(of: request.file)
            mode = current; original = current; octal = current.octal
        } catch { problem = error.localizedDescription }
    }
    private func apply() async {
        guard let mode else { return }
        working = true; problem = nil
        defer { working = false }
        do {
            try await provider().sftpSetPermissions(mode, on: request.file, recursive: recursive)
            dismiss()
        } catch { problem = error.localizedDescription }
    }
}
