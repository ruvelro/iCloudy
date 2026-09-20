import Foundation

@MainActor
struct MegaAuthentication {
    var session: URLSession = .shared

    func signInMega(email: String, password: String) async throws -> (Account, Credential) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), !address.hasPrefix("@"), !password.isEmpty else {
            throw CloudError.message(L("Escribe el correo y la contraseña de tu cuenta de Mega."))
        }
        // A second-factor code is typed after the password, separated by a space, because Mega asks for both at once.
        var secret = password
        var code: String?
        if let space = password.lastIndex(of: " ") {
            let tail = String(password[password.index(after: space)...])
            if tail.count == 6, tail.allSatisfy(\.isNumber) {
                code = tail
                secret = String(password[password.startIndex..<space])
            }
        }
        let signed = try await MegaAPI.signIn(email: address, password: secret, code: code, session: session)
        let account = Account(id: "mega:" + address, cloud: .mega, name: L("Mega"), email: address, clientID: "", clientSecret: nil)
        let credential = Credential(accessToken: signed.sid, refreshToken: "", expires: .distantFuture,
                                    secret: MegaCrypto.encode(signed.masterKey))
        return (account, credential)
    }
}
