import Foundation

/// What the connection form collects. Which fields matter depends on the service: AWS, Wasabi, Scaleway and Spaces
/// take a region from a list, B2 a region typed in, R2 the account id, and anything else a full endpoint.
struct S3SignIn: Equatable {
    var service: S3Service = .aws
    var region = ""
    var accountID = ""
    var endpoint = ""
    var accessKey = ""
    var secretKey = ""
    var bucket = ""
    var addressing: S3Addressing = .automatic
}

/// The keys of a sign-in that has not been saved yet, so the provider can sign its probe without touching the Keychain.
private final class ProbeCredentials: CredentialStore {
    let credential: Credential
    init(_ credential: Credential) { self.credential = credential }
    func read(_ key: String) throws -> Credential? { credential }
    func save(_ credential: Credential, key: String) throws {}
}

@MainActor
struct S3Authentication {
    var session: URLSession = .shared

    /// The endpoint the form describes, normalised: https unless typed otherwise, no trailing slash, no default port.
    static func endpoint(for form: S3SignIn, region: String) throws -> URLComponents {
        let typed: String
        if form.service == .custom {
            let trimmed = form.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            typed = trimmed.contains("://") ? trimmed : "https://" + trimmed
        } else if form.service == .cloudflare {
            let id = form.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                throw CloudError.message(L("Escribe el ID de cuenta de Cloudflare: está en el panel de R2, junto a la dirección S3."))
            }
            typed = form.service.endpoint(region: region, accountID: id.lowercased()) ?? ""
        } else {
            typed = form.service.endpoint(region: region) ?? ""
        }
        guard var components = URLComponents(string: typed), let host = components.host, !host.isEmpty,
              ["http", "https"].contains(components.scheme?.lowercased() ?? "") else {
            throw CloudError.message(L("Escribe una dirección de servicio válida, por ejemplo https://minio.ejemplo.com:9000"))
        }
        // The request is signed, so the secret itself never travels; the files and the signed requests would, in
        // clear, to anybody on the way. Plain HTTP is for a server in the same building only.
        if components.scheme?.lowercased() == "http", !LoginAddress.isLocalNetwork(host) {
            throw CloudError.message(L("Esa dirección no usa cifrado, y los archivos viajarían en claro. Usa https://, o una dirección de tu red local."))
        }
        components.scheme = components.scheme?.lowercased()
        components.host = host.lowercased()
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        if components.port == (components.scheme == "https" ? 443 : 80) { components.port = nil }
        if components.path.hasSuffix("/") { components.path = String(components.path.dropLast()) }
        return components
    }

    /// Proves the keys by listing the bucket, or the buckets, before anything is stored. On AWS a bucket in another
    /// region than the one chosen is found and the account is connected to the right one.
    func signIn(_ form: S3SignIn) async throws -> (Account, Credential) {
        let accessKey = form.accessKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let secretKey = form.secretKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accessKey.isEmpty, !secretKey.isEmpty else {
            throw CloudError.message(L("Introduce el ID de clave de acceso y la clave secreta."))
        }
        let bucket = form.bucket.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !bucket.contains("/") else { throw CloudError.message(L("El nombre del bucket no es válido.")) }
        var region = form.region.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if region.isEmpty { region = form.service.defaultRegion }
        var endpoint = try Self.endpoint(for: form, region: region)
        let credential = Credential(accessToken: accessKey, refreshToken: "", expires: .distantFuture, secret: secretKey)

        var account = Self.account(form.service, endpoint: endpoint, region: region, bucket: bucket, addressing: form.addressing, accessKey: accessKey)
        let probe = S3Provider(account: account, session: session, credentials: ProbeCredentials(credential))
        do {
            if bucket.isEmpty { _ = try await probe.s3Buckets() }
            else { _ = try await probe.s3(S3Call(bucket: bucket, query: [("list-type", "2"), ("max-keys", "1")])) }
        } catch let error as ServiceError where bucket.isEmpty && error.status == 403 {
            throw CloudError.message(L("Esta clave no puede listar los buckets. Escribe el nombre del bucket al que da acceso."))
        } catch CloudError.sessionExpired(let reason) {
            // A key the service does not know is a mistake in the form here, not an account to reconnect.
            throw CloudError.message(reason ?? L("El servicio no reconoce el ID de clave de acceso."))
        }
        if form.service == .aws, !bucket.isEmpty, let actual = probe.bucketRegions[bucket], actual != region,
           let moved = S3Service.aws.endpoint(region: actual).flatMap(URLComponents.init(string:)) {
            region = actual; endpoint = moved
            account = Self.account(form.service, endpoint: endpoint, region: region, bucket: bucket, addressing: form.addressing, accessKey: accessKey)
        }
        return (account, credential)
    }

    /// The id names the endpoint, the bucket and the key, so the same key on two buckets, or two keys on one bucket,
    /// are two accounts; signing in again with all three the same replaces the stored secret.
    static func account(_ service: S3Service, endpoint: URLComponents, region: String, bucket: String, addressing: S3Addressing, accessKey: String) -> Account {
        let host = (endpoint.host ?? "") + (endpoint.port.map { ":" + String($0) } ?? "") + endpoint.path
        let place = service == .custom ? host : [service.title, region == "auto" ? nil : region].compactMap { $0 }.joined(separator: " · ")
        var account = Account(id: "s3:" + host + "/" + bucket + "#" + accessKey, cloud: .s3,
                              name: bucket.isEmpty ? service.title : bucket, email: place,
                              clientID: "", clientSecret: nil, serverURL: endpoint.url?.absoluteString)
        account.options[S3Location.serviceOption] = service.rawValue
        account.options[S3Location.regionOption] = region
        if !bucket.isEmpty { account.options[S3Location.bucketOption] = bucket }
        account.options[S3Location.addressingOption] = addressing.rawValue
        return account
    }
}
