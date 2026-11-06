import Foundation

@MainActor
struct MegaAuthentication {
    var session: URLSession = .shared

    /// The password is used whole, spaces and all. When the account has a second factor, Mega says so and
    /// `askCode` asks for the code; by default the login form does, through `LoginPrompts`. Splitting a trailing
    /// "space and six digits" off the password, as this once did, broke every password that happened to end that way.
    func signInMega(email: String, password: String,
                    askCode: (@Sendable (_ retry: Bool) async -> String?)? = nil) async throws -> (Account, Credential) {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.contains("@"), !address.hasPrefix("@"), !password.isEmpty else {
            throw CloudError.message(L("Escribe el correo y la contraseña de tu cuenta de Mega."))
        }
        let ask = askCode ?? { retry in await LoginPrompts.shared.code(LoginPrompts.CodeQuestion(service: "Mega", retry: retry)) }
        let signed = try await MegaAPI.signIn(email: address, password: password, code: nil, askCode: ask, session: session)
        let account = Account(id: "mega:" + address, cloud: .mega, name: L("Mega"), email: address, clientID: "", clientSecret: nil)
        let credential = Credential(accessToken: signed.sid, refreshToken: "", expires: .distantFuture,
                                    secret: MegaCrypto.encode(signed.masterKey))
        return (account, credential)
    }
}

/// Mega's -26 while signing in: the account has a second factor and the code is missing, or was wrong.
struct MegaTwoFactorRequired: LocalizedError {
    var rejected = false
    var errorDescription: String? {
        rejected
            ? L("Mega no ha aceptado el código de verificación en dos pasos. Comprueba la hora de este Mac y escribe el código que muestra ahora tu aplicación de autenticación.")
            : L("Esta cuenta de Mega tiene verificación en dos pasos: hace falta el código de seis dígitos de tu aplicación de autenticación para conectarla.")
    }
}
