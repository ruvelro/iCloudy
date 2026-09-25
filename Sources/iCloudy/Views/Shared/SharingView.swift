import SwiftUI

/// An item whose sharing sheet is open.
struct SharingRequest: Identifiable {
    let id = UUID()
    let file: CloudFile
    let account: Account
}

extension AppModel {
    func requestSharing(_ file: CloudFile) {
        guard let account else { return }
        guard account.capabilities.memberSharing else {
            error = L("\(account.cloud.title) no permite compartir con personas desde iCloudy. Usa el enlace público o la web del proveedor.")
            return
        }
        sharing = SharingRequest(file: file, account: account)
    }
}

/// Who can open an item, and the form to add somebody. Every change goes straight to the provider: there is no
/// local state to fall out of step, only the list read back after each step.
struct SharingView: View {
    @ObservedObject var model: AppModel
    let request: SharingRequest
    @Environment(\.dismiss) private var dismiss
    @State private var permissions: [SharePermission] = []
    @State private var loading = true
    @State private var working = false
    @State private var recipient = ""
    @State private var role = ShareRole.viewer
    @State private var problem: String?
    @State private var notice: String?

    private var recipientPlaceholder: String {
        request.account.cloud == .webdav ? L("Usuario del servidor o correo") : L("Correo de la persona")
    }
    private var trimmed: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FileIcon(file: request.file)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Compartir «\(request.file.name)»").font(.title3.weight(.semibold)).lineLimit(1)
                    Text(model.accountTitle(request.account) + " · " + request.account.email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loading || working { ProgressView().controlSize(.small) }
            }
            Text(explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            List {
                if permissions.isEmpty && !loading {
                    Text("Nadie más tiene acceso.").foregroundStyle(.secondary)
                }
                ForEach(permissions) { permission in
                    HStack(spacing: 10) {
                        Image(systemName: icon(for: permission)).foregroundStyle(.secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.name).lineLimit(1)
                            if let email = permission.email, email != permission.name {
                                Text(email).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Spacer()
                        Text(label(for: permission)).font(.caption).foregroundStyle(.secondary)
                        if permission.canRevoke {
                            Button { Task { await revoke(permission) } } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.plain).help("Quitar el acceso").disabled(working)
                        }
                    }.padding(.vertical, 2)
                }
            }.frame(minHeight: 150, maxHeight: 260)
            HStack(spacing: 8) {
                TextField(recipientPlaceholder, text: $recipient).textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await share() } }
                Picker("Permiso", selection: $role) {
                    ForEach(ShareRole.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 130)
                Button("Compartir") { Task { await share() } }
                    .buttonStyle(.borderedProminent).disabled(working || trimmed.isEmpty || !Self.plausible(trimmed, cloud: request.account.cloud))
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            } else if let notice {
                Label(notice, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cerrar") { model.sharing = nil; dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(width: 520)
        .task { await load() }
    }

    private var explanation: String {
        switch request.account.cloud {
        case .webdav: return L("Un nombre se busca entre los usuarios del servidor; una dirección con @ se comparte por correo. El servidor avisa a la persona.")
        case .dropbox: return L("Dropbox avisa por correo. Una carpeta pasa a ser una carpeta compartida la primera vez que se comparte con alguien.")
        default: return L("La persona recibe un correo del proveedor con el acceso. Quitarla aquí lo revoca al momento.")
        }
    }
    private func icon(for permission: SharePermission) -> String {
        switch permission.kind {
        case .person: return permission.isOwner ? "person.crop.circle.badge.checkmark" : "person.crop.circle"
        case .group: return "person.2"
        case .domain: return "building.2"
        case .link: return "link"
        case .pending: return "envelope"
        }
    }
    private func label(for permission: SharePermission) -> String {
        if permission.isOwner { return L("Propietario") }
        let level = permission.role?.title ?? L("Acceso")
        if permission.kind == .pending { return level + " · " + L("pendiente") }
        if permission.isInherited { return level + " · " + L("heredado") }
        return level
    }
    /// Enough of a check to catch a slip before the provider does: an e-mail needs an @ and a dot after it; a
    /// Nextcloud user name can be anything without spaces.
    static func plausible(_ text: String, cloud: Cloud) -> Bool {
        guard !text.contains(where: \.isWhitespace) else { return false }
        if cloud == .webdav, !text.contains("@") { return !text.isEmpty }
        guard let at = text.firstIndex(of: "@"), at > text.startIndex else { return false }
        let domain = text[text.index(after: at)...]
        return domain.contains(".") && !domain.hasPrefix(".") && !domain.hasSuffix(".")
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { permissions = try await model.client(request.account).permissions(for: request.file); problem = nil }
        catch { problem = error.localizedDescription }
    }
    private func share() async {
        let who = trimmed
        guard !who.isEmpty, Self.plausible(who, cloud: request.account.cloud), !working else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.client(request.account).share(file: request.file, with: who, role: role)
            notice = L("«\(request.file.name)» compartido con \(who).")
            recipient = ""
            await load()
        } catch { problem = error.localizedDescription }
    }
    private func revoke(_ permission: SharePermission) async {
        guard !working else { return }
        working = true; problem = nil; notice = nil
        defer { working = false }
        do {
            try await model.client(request.account).revoke(permission, from: request.file)
            notice = L("\(permission.name) ya no tiene acceso.")
            await load()
        } catch { problem = error.localizedDescription }
    }
}
