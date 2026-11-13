import Foundation

/// What the Azure connection form collects.
struct AzureSignIn: Equatable {
    /// The storage account's name, or a full blob endpoint for Azurite, a sovereign cloud or a custom domain.
    var accountName = ""
    var endpoint = ""
    var auth: AzureAuth = .sharedKey
    /// The account key (Base64) or the SAS token, as the portal shows them.
    var secret = ""
    var container = ""
}

/// The secret of a sign-in that has not been saved yet, so the provider can sign its probe without the Keychain.
private final class AzureProbeCredentials: CredentialStore {
    let credential: Credential
    init(_ credential: Credential) { self.credential = credential }
    func read(_ key: String) throws -> Credential? { credential }
    func save(_ credential: Credential, key: String) throws {}
}

@MainActor
struct AzureAuthentication {
    var session: URLSession = .shared

    /// The endpoint the form describes: the public cloud's when only the account name is given, otherwise the one
    /// typed, https unless it is on the local network (Azurite).
    static func endpoint(for form: AzureSignIn) throws -> (name: String, endpoint: URLComponents) {
        let name = form.accountName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let typed = form.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty {
            guard (3...24).contains(name.count), name.allSatisfy({ $0.isLowercase || $0.isNumber }) else {
                throw CloudError.message(L("El nombre de una cuenta de almacenamiento tiene entre 3 y 24 letras minúsculas y números."))
            }
            return (name, URLComponents(string: "https://\(name).blob.core.windows.net")!)
        }
        guard var components = URLComponents(string: typed.contains("://") ? typed : "https://" + typed), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw CloudError.message(L("Escribe una dirección de servicio válida, por ejemplo https://cuenta.blob.core.windows.net"))
        }
        if components.scheme?.lowercased() == "http", !LoginAddress.isLocalNetwork(host) {
            throw CloudError.message(L("Esa dirección no usa cifrado, y los archivos viajarían en claro. Usa https://, o una dirección de tu red local."))
        }
        components.query = nil; components.fragment = nil; components.user = nil; components.password = nil
        while components.path.hasSuffix("/") { components.path.removeLast() }
        // The account name is the first label of the public endpoint, and Azurite's is the first path segment.
        let derived = name.isEmpty ? (host.hasSuffix(".blob.core.windows.net") ? String(host.split(separator: ".")[0])
                                                                             : components.path.split(separator: "/").first.map(String.init) ?? "") : name
        guard !derived.isEmpty else { throw CloudError.message(L("Escribe el nombre de la cuenta de almacenamiento.")) }
        return (derived, components)
    }

    static func account(_ form: AzureSignIn, name: String, endpoint: URLComponents) -> Account {
        let container = form.container.trimmingCharacters(in: .whitespacesAndNewlines)
        var account = Account(id: "azure:" + (endpoint.host ?? name) + endpoint.path + "/" + container + "#" + form.auth.rawValue,
                              cloud: .azure, name: container.isEmpty ? name : container,
                              email: name + (container.isEmpty ? "" : " · " + container), clientID: "", clientSecret: nil,
                              serverURL: endpoint.url?.absoluteString)
        account.options[AzureLocation.accountOption] = name
        account.options[AzureLocation.authOption] = form.auth.rawValue
        if !container.isEmpty { account.options[AzureLocation.containerOption] = container }
        return account
    }

    /// Lists the container (or the containers) with the key or token before anything is stored.
    func signIn(_ form: AzureSignIn) async throws -> (Account, Credential) {
        let (name, endpoint) = try Self.endpoint(for: form)
        var secret = form.secret.trimmingCharacters(in: .whitespacesAndNewlines)
        if form.auth == .sas, secret.hasPrefix("?") { secret.removeFirst() }
        switch form.auth {
        case .sharedKey:
            guard let key = Data(base64Encoded: secret), !key.isEmpty else {
                throw CloudError.message(L("La clave de la cuenta no es válida: cópiala entera desde «Claves de acceso» en el portal de Azure."))
            }
        case .sas:
            guard secret.contains("sig=") else {
                throw CloudError.message(L("Pega el token SAS entero (empieza por sv= y contiene sig=)."))
            }
        }
        let account = Self.account(form, name: name, endpoint: endpoint)
        let credential = Credential(accessToken: name, refreshToken: "", expires: .distantFuture, secret: secret)
        let probe = AzureProvider(account: account, session: session, credentials: AzureProbeCredentials(credential))
        do { _ = try await probe.list(parent: "root") }
        catch let error as ServiceError where error.status == 403 && form.container.isEmpty {
            throw CloudError.message(L("Las credenciales no pueden listar los contenedores de la cuenta. Si solo tienen acceso a uno, escribe su nombre en «Contenedor».") + " " + (error.detail ?? ""))
        } catch CloudError.sessionExpired(let reason) {
            throw CloudError.message(reason ?? L("Azure no acepta la clave o el token SAS de esta cuenta. Vuelve a conectarla con unos válidos."))
        }
        return (account, credential)
    }
}
