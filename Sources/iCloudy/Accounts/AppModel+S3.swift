import AppKit
import SwiftUI

/// A provider whose links are URLs it signs itself, valid for a lifetime chosen when they are made: S3's presigned
/// URLs and Azure's SAS.
@MainActor
protocol TemporaryLinkProvider {
    func temporaryLink(for file: CloudFile, lifetime: Int) throws -> URL
}
extension S3Provider: TemporaryLinkProvider {}

extension AppModel {
    /// Connects an S3 account once its keys have listed what they claim to reach. The secret key is stored in the
    /// Keychain with the access key and is never sent anywhere: it only derives the signature of each request.
    /// Connects an Azure storage account once its key or SAS token has listed what it claims to reach.
    func connectAzure(_ form: AzureSignIn) async {
        guard !ui.connecting else { return }
        ui.connectionError = nil; ui.connecting = true
        defer { ui.connecting = false }
        do {
            let (account, credential) = try await AzureAuthentication().signIn(form)
            try adopt(account, credential: credential)
            ui.serverLogin = nil; ui.reconnecting = nil
            select(account.id); ui.showConnect = false
        } catch { ui.connectionError = error.localizedDescription }
    }

    func connectS3(_ form: S3SignIn) async {
        guard !ui.connecting else { return }
        ui.connectionError = nil; ui.connecting = true
        defer { ui.connecting = false }
        do {
            let (account, credential) = try await S3Authentication().signIn(form)
            try adopt(account, credential: credential)
            ui.serverLogin = nil; ui.reconnecting = nil
            select(account.id); ui.showConnect = false
        } catch { ui.connectionError = error.localizedDescription }
    }

    /// Copies a presigned link that stops working after `lifetime` seconds. S3 has no public links of its own, so
    /// this is the closest thing, and the message says plainly that it expires.
    func createTemporaryLink(_ file: CloudFile, account: Account, lifetime: Int) async {
        do {
            guard let provider = try client(account).provider as? TemporaryLinkProvider else {
                throw CloudError.message(L("\(account.cloud.title) no crea enlaces públicos desde iCloudy."))
            }
            let link = try provider.temporaryLink(for: file, lifetime: lifetime)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            let expiry = Date().addingTimeInterval(TimeInterval(lifetime)).formatted(date: .abbreviated, time: .shortened)
            info = L("Enlace temporal copiado. Cualquiera que lo tenga podrá descargar «\(file.name)» hasta el \(expiry). No se puede revocar antes salvo desactivando la clave de acceso.")
        } catch { self.error = error.localizedDescription }
    }
}
