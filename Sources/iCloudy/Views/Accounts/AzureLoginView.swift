import SwiftUI

/// The storage account, its key or a SAS token, and optionally one container. The secret goes to the Keychain and
/// only ever signs requests (a key) or rides on them (a SAS token).
struct AzureLoginView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var form = AzureSignIn()
    @State private var showAdvanced = false

    private func prefillForReconnect() {
        guard form.accountName.isEmpty, let account = model.ui.reconnecting, let location = try? AzureLocation(account: account) else { return }
        form.accountName = location.accountName
        form.auth = location.auth
        form.container = location.container ?? ""
        if location.endpoint.host != "\(location.accountName).blob.core.windows.net" {
            form.endpoint = location.endpoint.url?.absoluteString ?? ""; showAdvanced = true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Label("Azure Blob Storage", systemImage: "square.stack.3d.down.right").font(.title2)
                Text("Experimental").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.orange.opacity(0.18), in: Capsule()).foregroundStyle(.orange)
            }
            Text("Con la clave de la cuenta («Claves de acceso» en el portal) iCloudy firma cada petición y puede crear enlaces temporales. Con un token SAS, solo hace lo que el token permite.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Nombre de la cuenta de almacenamiento", text: $form.accountName).textFieldStyle(.roundedBorder)
                .onAppear(perform: prefillForReconnect)
            Picker("Credencial", selection: $form.auth) {
                Text("Clave de la cuenta").tag(AzureAuth.sharedKey)
                Text("Token SAS").tag(AzureAuth.sas)
            }.pickerStyle(.segmented)
            SecureField(form.auth == .sharedKey ? "Clave de la cuenta" : "Token SAS (sv=…&sig=…)", text: $form.secret).textFieldStyle(.roundedBorder)
            TextField("Contenedor (opcional)", text: $form.container).textFieldStyle(.roundedBorder)
            Text("Vacío, se muestran todos los contenedores que la credencial puede listar. Escríbelo si solo tiene acceso a uno.")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup(isExpanded: $showAdvanced) {
                TextField("https://cuenta.blob.core.windows.net", text: $form.endpoint).textFieldStyle(.roundedBorder)
                Text("Solo para nubes soberanas, dominios propios o Azurite (http://127.0.0.1:10000/devstoreaccount1).")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } label: { Text("Avanzado").font(.caption) }
            if let error = model.ui.connectionError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancelar") { model.ui.serverLogin = nil; model.ui.reconnecting = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if model.ui.connecting { ProgressView().controlSize(.small) }
                Button("Conectar") {
                    Task {
                        await model.connectAzure(form)
                        form.secret = ""
                        if model.ui.connectionError == nil { dismiss() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.ui.connecting || form.secret.isEmpty || (form.accountName.isEmpty && form.endpoint.isEmpty))
            }
        }.padding(24).frame(width: 470)
    }
}
