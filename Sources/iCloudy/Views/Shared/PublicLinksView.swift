import AppKit
import SwiftUI

/// An item whose public links sheet is open.
struct PublicLinksRequest: Identifiable {
    let id = UUID()
    let file: CloudFile
    let account: Account
}

extension AppModel {
    func requestPublicLinks(_ file: CloudFile, account target: Account? = nil) {
        guard let account = target ?? account else { return }
        guard account.capabilities.links.manage else { error = L("\(account.cloud.title) no gestiona enlaces públicos desde iCloudy."); return }
        publicLinkManager = PublicLinksRequest(file: file, account: account)
    }
    /// Opens the account-wide list. A provider that cannot enumerate its links still opens it, to say so.
    func requestLinkInventory(_ account: Account) {
        guard account.capabilities.links.manage else { error = L("\(account.cloud.title) no gestiona enlaces públicos desde iCloudy."); return }
        linkInventory = account
    }
    func copyToPasteboard(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

/// The public links of one item, and the form to make another. Revoking always goes through a confirmation, and every
/// change is read back from the provider rather than assumed.
struct PublicLinksView: View {
    @ObservedObject var model: AppModel
    let request: PublicLinksRequest
    @Environment(\.dismiss) private var dismiss
    @State private var links: [PublicLink] = []
    @State private var loading = true
    @State private var working = false
    @State private var problem: String?
    @State private var notice: String?
    @State private var pendingRevoke: PublicLink?
    @State private var access = LinkAccess.view
    @State private var expires = false
    @State private var expiryDay = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var protected = false
    @State private var password = ""
    @State private var allowDownload = true

    private var file: CloudFile { request.file }
    private var features: LinkFeatures { request.account.capabilities.links }
    /// Why no new link can be made for this item, such as a Mega folder; its existing links can still be revoked.
    private var creationBlocked: String? { request.account.limitation(.publicLink, for: [file]) }
    private var offersEdit: Bool { features.edit && (!file.isFolder || features.editFolders) }
    private var options: PublicLinkOptions {
        PublicLinkOptions(access: offersEdit ? access : .view,
                          expires: features.expiration && expires ? LinkDates.endOfDay(expiryDay) : nil,
                          password: features.password && protected ? password : nil,
                          allowDownload: features.downloadToggle && access == .view ? allowDownload : true)
    }
    private var ready: Bool { !working && creationBlocked == nil && (!protected || !password.isEmpty) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FileIcon(file: file)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enlaces públicos de «\(file.name)»").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(model.accountTitle(request.account) + " · " + request.account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loading || working { ProgressView().controlSize(.small) }
            }
            List {
                if links.isEmpty && !loading {
                    Text("Este elemento no tiene enlaces públicos.").foregroundStyle(.secondary)
                }
                ForEach(links) { link in
                    PublicLinkRow(link: link, busy: working, copy: { copy(link) }, revoke: { pendingRevoke = link })
                }
            }.frame(minHeight: 110, maxHeight: 220)
            GroupBox("Nuevo enlace") { form.padding(6) }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cerrar") { model.publicLinkManager = nil; dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 560)
        .task { await load() }
        .confirmationDialog("¿Revocar este enlace?", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
                            titleVisibility: .visible, presenting: pendingRevoke) { link in
            Button("Revocar enlace", role: .destructive) { Task { await revoke(link) } }
            Button("Cancelar", role: .cancel) { pendingRevoke = nil }
        } message: { _ in
            Text("Quien tenga el enlace dejará de poder abrir «\(file.name)». No se puede deshacer: un enlace nuevo tendrá otra dirección.")
        }
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let creationBlocked {
                Text(creationBlocked).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                if offersEdit {
                    Picker("Permiso", selection: $access) {
                        ForEach(LinkAccess.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).frame(maxWidth: 260)
                }
                if features.expiration {
                    HStack(spacing: 8) {
                        Toggle("Caduca el", isOn: $expires)
                        DatePicker("Fecha de caducidad", selection: $expiryDay, in: Date()..., displayedComponents: .date)
                            .labelsHidden().disabled(!expires)
                    }
                }
                if features.password {
                    HStack(spacing: 8) {
                        Toggle("Con contraseña", isOn: $protected)
                        SecureField("Contraseña del enlace", text: $password).textFieldStyle(.roundedBorder).disabled(!protected).frame(maxWidth: 220)
                    }
                }
                if features.downloadToggle && access == .view {
                    Toggle("Permitir descargar", isOn: $allowDownload)
                }
                Text(PublicLinkNotes.creation(request.account.cloud)).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline) {
                    Group {
                        if options.access == .edit { Text("Cualquiera con el enlace podrá ver y editar «\(file.name)» sin iniciar sesión.") }
                        else { Text("Cualquiera con el enlace podrá ver «\(file.name)» sin iniciar sesión.") }
                    }.font(.caption).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Crear y copiar enlace") { Task { await create() } }
                        .buttonStyle(.borderedProminent).disabled(!ready)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { links = try await model.client(request.account).publicLinks(for: file); problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func copy(_ link: PublicLink) {
        guard let url = link.url else { return }
        model.copyToPasteboard(url)
        problem = nil; notice = L("Enlace copiado.")
    }
    private func create() async {
        guard ready else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            let link = try await model.client(request.account).createPublicLink(for: file, options: options)
            if let url = link.url { model.copyToPasteboard(url); notice = L("Enlace creado y copiado.") }
            else { notice = L("Enlace creado.") }
            password = ""; protected = false
            await load()
        } catch { problem = error.localizedDescription }
    }
    private func revoke(_ link: PublicLink) async {
        pendingRevoke = nil
        guard !working else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.client(request.account).revokePublicLink(link)
            notice = L("Enlace revocado. Ya no abre «\(file.name)».")
            await load()
        } catch { problem = error.localizedDescription }
    }
}

/// One link in a list: its address, what it allows, and the two things that can be done with it.
struct PublicLinkRow: View {
    let link: PublicLink
    /// The account-wide list names the item; the item's own sheet does not need to.
    var showsItem = false
    let busy: Bool
    let copy: () -> Void
    let revoke: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if showsItem { FileIcon(file: link.file) } else { Image(systemName: "link").foregroundStyle(.secondary).frame(width: 18) }
            VStack(alignment: .leading, spacing: 2) {
                if showsItem {
                    Text(link.file.name).lineLimit(1)
                    if let location = link.location { Text(location).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                }
                if let url = link.url {
                    Text(url.absoluteString).font(showsItem ? .caption : .body).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else {
                    Text("Sin una dirección que iCloudy pueda mostrar").font(.caption).foregroundStyle(.secondary)
                }
                Text(Self.details(link)).font(.caption).foregroundStyle(Self.expired(link) ? .orange : .secondary).lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(action: copy) { Image(systemName: "doc.on.doc") }
                .buttonStyle(.plain).help("Copiar enlace").accessibilityLabel("Copiar enlace").disabled(link.url == nil)
            if link.canRevoke {
                Button(action: revoke) { Image(systemName: "xmark.circle") }
                    .buttonStyle(.plain).help("Revocar enlace…").accessibilityLabel("Revocar enlace…").disabled(busy)
            } else {
                Image(systemName: "lock").foregroundStyle(.secondary).help("Viene de una carpeta superior: se revoca allí")
            }
        }.padding(.vertical, 2)
    }

    static func expired(_ link: PublicLink, now: Date = Date()) -> Bool { link.expires.map { $0 < now } ?? false }

    /// Everything that limits the link, in one line.
    static func details(_ link: PublicLink, now: Date = Date()) -> String {
        var parts = [link.access.title]
        if let expires = link.expires {
            let day = expires.formatted(date: .abbreviated, time: .omitted)
            parts.append(expires < now ? L("Caducó el \(day)") : L("Caduca el \(day)"))
        } else {
            parts.append(L("Sin caducidad"))
        }
        if link.hasPassword { parts.append(L("Con contraseña")) }
        if link.allowsDownload == false { parts.append(L("Sin descarga")) }
        if let audience = link.audience { parts.append(audience) }
        if link.isInherited { parts.append(L("Heredado")) }
        return parts.joined(separator: " · ")
    }
}
