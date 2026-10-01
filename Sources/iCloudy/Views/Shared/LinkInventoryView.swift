import SwiftUI

/// Every public link an account has made, where the provider can list them, with copy and revoke. Where it cannot
/// (OneDrive, Box) the sheet says so and points to the item's own sheet instead of showing an empty list.
struct LinkInventoryView: View {
    @ObservedObject var model: AppModel
    let account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var links: [PublicLink] = []
    @State private var loading = false
    @State private var working = false
    @State private var loaded = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var filter = ""
    @State private var pendingRevoke: PublicLink?

    private var features: LinkFeatures { account.capabilities.links }
    private var visible: [PublicLink] {
        let term = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return links }
        return links.filter { $0.file.name.localizedCaseInsensitiveContains(term) || ($0.location ?? "").localizedCaseInsensitiveContains(term) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "link").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enlaces compartidos").font(.title3.weight(.semibold))
                    Text(model.accountTitle(account) + " · " + account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loading || working { ProgressView().controlSize(.small) }
                if features.inventory {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Actualizar").accessibilityLabel("Actualizar").disabled(loading || working)
                }
            }
            if features.inventory {
                Text("Los enlaces públicos que ha creado esta cuenta. Revocar uno lo desactiva para todo el que lo tenga.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField("Filtrar por nombre o carpeta", text: $filter).textFieldStyle(.roundedBorder)
                List {
                    if visible.isEmpty && loaded && !loading {
                        Group {
                            if links.isEmpty { Text("Esta cuenta no tiene enlaces públicos.") } else { Text("Ningún enlace coincide con el filtro.") }
                        }.foregroundStyle(.secondary)
                    }
                    ForEach(visible) { link in
                        PublicLinkRow(link: link, showsItem: true, busy: working, copy: { copy(link) }, revoke: { pendingRevoke = link })
                    }
                }.frame(minHeight: 220, maxHeight: 380)
                if loaded { Text("\(links.count) enlaces").font(.caption).foregroundStyle(.secondary) }
            } else {
                Label {
                    Text(PublicLinkNotes.noInventory(account.cloud)).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "info.circle") }
                .font(.callout)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cerrar") { model.linkInventory = nil; dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 600)
        .task { if features.inventory { await load() } }
        .confirmationDialog("¿Revocar este enlace?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible, presenting: pendingRevoke) { link in
            Button("Revocar enlace", role: .destructive) { Task { await revoke(link) } }
            Button("Cancelar", role: .cancel) { pendingRevoke = nil }
        } message: { link in
            Text("Quien tenga el enlace dejará de poder abrir «\(link.file.name)». No se puede deshacer: un enlace nuevo tendrá otra dirección.")
        }
    }

    private func load() async {
        loading = true; defer { loading = false; loaded = true }
        do { links = try await model.client(account).allPublicLinks(); problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func copy(_ link: PublicLink) {
        guard let url = link.url else { return }
        model.copyToPasteboard(url)
        problem = nil; notice = L("Enlace copiado.")
    }
    private func revoke(_ link: PublicLink) async {
        pendingRevoke = nil
        guard !working else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.client(account).revokePublicLink(link)
            notice = L("Enlace revocado. Ya no abre «\(link.file.name)».")
            await load()
        } catch { problem = error.localizedDescription }
    }
}
