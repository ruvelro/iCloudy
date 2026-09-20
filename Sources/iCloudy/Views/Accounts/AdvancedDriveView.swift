import SwiftUI
import AppKit
import CoreSpotlight
import UniformTypeIdentifiers

/// Picks a shared drive or a document library from an account that is already connected. Kept out of the main list
/// because most people never need one, and it needs an existing sign-in rather than a new one.
struct AdvancedDriveView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host: Account?
    @State private var drives: [RemoteDrive] = []
    @State private var loading = false
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Unidad compartida o biblioteca").font(.title2)
            Text("Se añade como una nube más, reutilizando la sesión de la cuenta elegida. No hay que iniciar sesión otra vez.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Cuenta", selection: Binding(get: { host }, set: { host = $0; Task { await load() } })) {
                Text("Elige una cuenta").tag(Account?.none)
                ForEach(model.driveHosts) { account in
                    Text(model.accountTitle(account) + " · " + account.email).tag(Account?.some(account))
                }
            }.labelsHidden()
            List(drives) { drive in
                HStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.person.crop").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text(drive.name).fontWeight(.medium)
                        Text(drive.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "plus.circle")
                }.contentShape(Rectangle())
                    .onTapGesture { if let host { model.addScopedDrive(drive, from: host); dismiss() } }
            }
            .frame(minHeight: 200)
            .overlay {
                if loading { ProgressView() }
                else if host == nil { Text("Elige primero una cuenta.").foregroundStyle(.secondary).font(.callout) }
                else if drives.isEmpty { Text("Esa cuenta no tiene unidades compartidas ni bibliotecas disponibles.").foregroundStyle(.secondary).font(.callout).multilineTextAlignment(.center).padding() }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack { Spacer(); Button("Cerrar") { model.showAdvanced = false; dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 520)
    }
    private func load() async {
        guard let host else { return }
        loading = true; failure = nil; drives = []
        do { drives = try await model.client(host).availableDrives() }
        catch { failure = error.localizedDescription }
        loading = false
    }
}
