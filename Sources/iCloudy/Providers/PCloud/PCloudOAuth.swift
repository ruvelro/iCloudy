import Foundation

extension OAuthProviderSettings {
    /// pCloud has no PKCE: the code is exchanged with the client secret, which travels inside the app as Box's does.
    /// Its token endpoint and profile depend on the account's region, so the endpoints here are only the defaults;
    /// `PCloudAuthentication` picks the right host once the browser comes back.
    static let pcloud = OAuthProviderSettings(
        authorizationEndpoint: "https://my.pcloud.com/oauth2/authorize", tokenEndpoint: "https://api.pcloud.com/oauth2_token",
        profileEndpoint: "https://api.pcloud.com/userinfo", identityKey: "userid", profileMethod: "GET",
        toleratesAnyPort: false, usesClientSecret: true,
        authorizationParameters: [:], toleratesMissingState: true)
}

/// The part of pCloud's sign-in that differs from the other providers. The browser comes back with the code and the
/// account's region (`hostname`, `locationid`), and the code is only good on that region's host. The token it buys
/// never expires and comes with no refresh token, so it is stored as a permanent credential.
@MainActor
enum PCloudAuthentication {
    static func complete(code: String, callback: [URLQueryItem], clientID: String, clientSecret: String,
                         session: URLSession) async throws -> (Account, Credential) {
        let named = callback.first { $0.name == "hostname" }?.value ?? ""
        // The client secret goes with the code, so a host that is not one of pCloud's two never receives it.
        guard named.isEmpty || PCloudRegion.host(named: named) != nil else {
            throw CloudError.message(L("pCloud indicó un servidor desconocido al volver del inicio de sesión. Vuelve a intentarlo."))
        }
        let announced = PCloudRegion.host(named: named)
            ?? PCloudRegion.host(locationID: callback.first { $0.name == "locationid" }?.value.flatMap { Int($0) })
        var tokenHost = announced ?? PCloudRegion.unitedStates
        var tokens: [String: Any]
        do { tokens = try await exchange(code: code, clientID: clientID, clientSecret: clientSecret, host: tokenHost, session: session) }
        catch let error as ServiceError where error.code == "pcloud.2012" && announced == nil {
            // Without a region in the callback the code was tried in the United States. A European account's code
            // is unknown there, and so still unused: Europe is asked next.
            tokenHost = PCloudRegion.europe
            tokens = try await exchange(code: code, clientID: clientID, clientSecret: clientSecret, host: tokenHost, session: session)
        }
        guard let access = tokens["access_token"] as? String, !access.isEmpty else {
            throw CloudError.message(L("pCloud no devolvió el acceso. Repite el consentimiento."))
        }
        let locationID = (tokens["locationid"] as? NSNumber)?.intValue
        let apiHost = PCloudRegion.host(named: tokens["hostname"] as? String) ?? PCloudRegion.host(locationID: locationID) ?? tokenHost

        var request = URLRequest(url: URL(string: "https://\(apiHost)/userinfo")!)
        request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        try HTTP.validate(response, data: data)
        let profile = try PCloudError.check(try HTTP.json(data))
        guard let identity = (profile["userid"] as? NSNumber)?.stringValue else { throw CloudError.message(L("No se pudo identificar la cuenta.")) }
        let email = profile["email"] as? String ?? identity
        var options = ["apiHost": apiHost]
        if let locationID { options["locationid"] = String(locationID) }
        // The secret is not kept with the account: with no refresh token there is nothing it would be needed for.
        let account = Account(id: "pcloud:" + identity, cloud: .pcloud, name: email, email: email, clientID: clientID, clientSecret: nil,
                              serverURL: nil, bookmark: nil, options: options)
        return (account, .permanent(accessToken: access))
    }

    /// `oauth2_token` answers HTTP 200 with a `result` code like every other pCloud method.
    private static func exchange(code: String, clientID: String, clientSecret: String, host: String, session: URLSession) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://\(host)/oauth2_token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = HTTP.form(["client_id": clientID, "client_secret": clientSecret, "code": code])
        let (data, response) = try await session.data(for: request, delegate: RedirectGuard.shared)
        try HTTP.validate(response, data: data)
        return try PCloudError.check(try HTTP.json(data))
    }
}
