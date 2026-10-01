import AppKit
import SwiftUI

extension AppModel {
    /// Connects an S3 account once its keys have listed what they claim to reach. The secret key is stored in the
    /// Keychain with the access key and is never sent anywhere: it only derives the signature of each request.
    func connectS3(_ form: S3SignIn) async {
        guard !connecting else { return }
        connectionError = nil; connecting = true
        defer { connecting = false }
        do {
            let (account, credential) = try await S3Authentication().signIn(form)
            try adopt(account, credential: credential)
            serverLogin = nil; reconnecting = nil
            select(account.id); showConnect = false
        } catch { connectionError = error.localizedDescription }
    }

    /// Copies a presigned link that stops working after `lifetime` seconds. S3 has no public links of its own, so
    /// this is the closest thing, and the message says plainly that it expires.
    func createTemporaryLink(_ file: CloudFile, account: Account, lifetime: Int) async {
        do {
            guard let provider = try client(account).provider as? S3Provider else {
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
