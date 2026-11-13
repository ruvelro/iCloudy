import Foundation

/// Connects a Telegram channel through a bot the person creates in BotFather. There is no OAuth and no application
/// to register: the token *is* the credential, and it goes straight to the Keychain.
@MainActor
struct TelegramAuthentication {
    var session: URLSession = .shared

    /// Everything that can be checked before anything is stored is checked here, because every one of these
    /// failures is silent later on. The bot has to exist, the channel has to be reachable *by that bot*, and the
    /// bot has to be an administrator that may post: a bot merely added to a channel can see nothing and write
    /// nothing, and the only symptom would be an account that looks connected and refuses every upload.
    func signInTelegram(channel: String, token: String) async throws -> (Account, Credential) {
        let secret = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isTelegramToken(secret) else {
            throw CloudError.message(L("Eso no parece un token de bot. BotFather los entrega con la forma 123456789:AA... Cópialo entero."))
        }
        guard let chat = Self.telegramChat(channel) else {
            throw CloudError.message(L("Escribe el identificador del canal, por ejemplo -1001234567890, o su @nombre si es público."))
        }
        let identity = try await probe("getMe", token: secret, query: [])
        guard let bot = identity["username"] as? String, let botID = (identity["id"] as? NSNumber)?.intValue else {
            throw CloudError.message(L("Telegram no reconoció ese token de bot."))
        }
        let chatQuery = [URLQueryItem(name: "chat_id", value: chat)]
        let target = try await probe("getChat", token: secret, query: chatQuery)
        let kind = target["type"] as? String ?? ""
        guard ["channel", "supergroup", "group"].contains(kind) else {
            throw CloudError.message(L("Eso no es un canal ni un grupo. Crea un canal privado, añade el bot como administrador y vuelve a intentarlo."))
        }
        let membership = try await probe("getChatMember", token: secret,
                                         query: chatQuery + [URLQueryItem(name: "user_id", value: String(botID))])
        let status = membership["status"] as? String ?? ""
        guard ["administrator", "creator"].contains(status) else {
            throw CloudError.message(L("El bot está en el canal pero no es administrador, así que no puede publicar ni leer nada. Dale el permiso de administrador y vuelve a intentarlo."))
        }
        // A channel needs "post messages"; in a group being an administrator is enough to write.
        if kind == "channel", membership["can_post_messages"] as? Bool == false {
            throw CloudError.message(L("El bot es administrador del canal pero no puede publicar mensajes. Activa ese permiso y vuelve a intentarlo."))
        }
        let title = target["title"] as? String ?? chat
        let account = Account(id: "telegram:" + chat, cloud: .telegram, name: title,
                              email: "@" + bot + " · " + title, clientID: "", clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: ["chat": chat, "bot": bot])
        // A bot token lasts until its owner revokes it in BotFather. There is nothing to refresh and nothing to expire.
        return (account, Credential(accessToken: secret, refreshToken: "", expires: .distantFuture))
    }

    /// One Bot API call during sign-in. It cannot go through the provider, which does not exist yet at this point.
    private func probe(_ method: String, token: String, query: [URLQueryItem]) async throws -> [String: Any] {
        guard let url = TelegramAPI.endpoint(token: token, method: method, query: query) else {
            throw CloudError.message(L("No se pudo construir la petición a Telegram."))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        do { return try TelegramAPI.result(data, response: response, token: token) }
        catch let failure as TelegramAPI.Failure {
            switch failure.code {
            case 401:
                throw CloudError.message(L("Telegram rechazó el token del bot. Comprueba que lo has copiado entero y que no lo has revocado en BotFather."))
            case 400, 403:
                throw CloudError.message(L("Telegram no deja a este bot llegar a ese canal: \(failure.detail). Añádelo al canal como administrador antes de conectarlo."))
            default:
                throw CloudError.message(failure.detail)
            }
        }
    }

    /// BotFather hands out `<identificador>:<secreto>`. Checking the shape here turns a pasted half-token into a
    /// sentence instead of an HTTP 404 from a URL that cannot be shown because it contains the token.
    nonisolated static func isTelegramToken(_ value: String) -> Bool {
        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count >= 5, parts[0].allSatisfy(\.isNumber), parts[1].count >= 20,
              parts[1].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else { return false }
        return true
    }
    /// Turns whatever the person pasted into something `chat_id` accepts: a numeric identifier or an @name. The
    /// links are here because copying one from Telegram is far easier than finding the number behind it.
    nonisolated static func telegramChat(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for prefix in ["https://t.me/", "http://t.me/", "t.me/", "https://telegram.me/", "telegram.me/"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        // A private channel's own link is t.me/c/<resto>/<mensaje>, and the identifier is that rest behind "-100".
        if value.hasPrefix("c/") {
            let digits = value.dropFirst(2).prefix { $0.isNumber }
            guard digits.count >= 6 else { return nil }
            return "-100" + String(digits)
        }
        value = value.split(separator: "/").first.map { String($0) } ?? value
        if value.hasPrefix("@") { value = String(value.dropFirst()) }
        if Int64(value) != nil { return value }
        guard value.count >= 4, value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        return "@" + value
    }
}
