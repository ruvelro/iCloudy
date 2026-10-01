import Foundation

/// The services iCloudy knows how to address without being told the endpoint. They all speak the same API; what
/// changes is the host name, the region names and how picky the host is about bucket subdomains.
enum S3Service: String, CaseIterable, Identifiable {
    case aws, backblaze, wasabi, cloudflare, scaleway, digitalocean, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .aws: return L("Amazon S3")
        case .backblaze: return L("Backblaze B2")
        case .wasabi: return L("Wasabi")
        case .cloudflare: return L("Cloudflare R2")
        case .scaleway: return L("Scaleway")
        case .digitalocean: return L("DigitalOcean Spaces")
        case .custom: return L("MinIO u otro compatible")
        }
    }
    /// Regions offered in a picker. Empty where the region is free text (B2 names its clusters) or fixed (R2).
    var regions: [String] {
        switch self {
        case .aws:
            return ["us-east-1", "us-east-2", "us-west-1", "us-west-2", "ca-central-1", "sa-east-1",
                    "eu-west-1", "eu-west-2", "eu-west-3", "eu-central-1", "eu-central-2", "eu-north-1", "eu-south-1", "eu-south-2",
                    "me-central-1", "af-south-1", "ap-south-1", "ap-northeast-1", "ap-northeast-2", "ap-northeast-3",
                    "ap-southeast-1", "ap-southeast-2"]
        case .wasabi:
            return ["us-east-1", "us-east-2", "us-central-1", "us-west-1", "ca-central-1", "eu-central-1", "eu-central-2",
                    "eu-west-1", "eu-west-2", "eu-south-1", "ap-northeast-1", "ap-northeast-2", "ap-southeast-1", "ap-southeast-2"]
        case .scaleway: return ["fr-par", "nl-ams", "pl-waw"]
        case .digitalocean: return ["nyc3", "sfo3", "ams3", "fra1", "lon1", "sgp1", "syd1", "blr1", "tor1"]
        case .backblaze, .cloudflare, .custom: return []
        }
    }
    var defaultRegion: String {
        switch self {
        case .aws: return "eu-west-1"
        case .backblaze: return "eu-central-003"
        case .wasabi: return "eu-central-1"
        case .cloudflare: return "auto"
        case .scaleway: return "fr-par"
        case .digitalocean: return "ams3"
        case .custom: return "us-east-1"
        }
    }
    /// The service endpoint for `region`; R2 needs the account id instead. Nil for a custom endpoint, which the person types.
    func endpoint(region: String, accountID: String = "") -> String? {
        switch self {
        case .aws: return "https://s3.\(region).amazonaws.com"
        case .backblaze: return "https://s3.\(region).backblazeb2.com"
        case .wasabi: return "https://s3.\(region).wasabisys.com"
        case .cloudflare: return accountID.isEmpty ? nil : "https://\(accountID).r2.cloudflarestorage.com"
        case .scaleway: return "https://s3.\(region).scw.cloud"
        case .digitalocean: return "https://\(region).digitaloceanspaces.com"
        case .custom: return nil
        }
    }
    /// A self-hosted server is usually one host with no wildcard DNS or certificate, and R2's certificate does not
    /// cover a subdomain of the account's own; both are addressed by path unless told otherwise.
    var prefersPathStyle: Bool { [.custom, .cloudflare].contains(self) }
}

/// Path-style puts the bucket in the path (`host/bucket/key`); virtual-hosted puts it in the host (`bucket.host/key`).
enum S3Addressing: String, CaseIterable, Identifiable {
    case automatic, path, virtual
    var id: String { rawValue }
}

/// Where an S3 account's requests go, read from the account. `serverURL` is the service endpoint, without bucket;
/// the rest lives in `options`.
struct S3Location: Equatable {
    let service: S3Service
    /// Scheme, host, port and an optional base path, as typed for a custom endpoint.
    let endpoint: URLComponents
    let region: String
    /// The one bucket the account is restricted to, or nil to show every bucket the key can list.
    let bucket: String?
    let addressing: S3Addressing

    static let serviceOption = "s3Service", regionOption = "region", bucketOption = "bucket", addressingOption = "addressing"

    init(service: S3Service, endpoint: URLComponents, region: String, bucket: String?, addressing: S3Addressing) {
        self.service = service; self.endpoint = endpoint; self.region = region
        self.bucket = bucket.flatMap { $0.isEmpty ? nil : $0 }; self.addressing = addressing
    }

    init(account: Account) throws {
        guard let server = account.serverURL, let components = URLComponents(string: server), components.host?.isEmpty == false else {
            throw CloudError.message(L("Esta cuenta S3 no tiene una dirección de servicio válida. Vuelve a conectarla."))
        }
        self.init(service: account.options[Self.serviceOption].flatMap(S3Service.init(rawValue:)) ?? .custom,
                  endpoint: components,
                  region: account.options[Self.regionOption].flatMap { $0.isEmpty ? nil : $0 } ?? "us-east-1",
                  bucket: account.options[Self.bucketOption],
                  addressing: account.options[Self.addressingOption].flatMap(S3Addressing.init(rawValue:)) ?? .automatic)
    }

    var isSecure: Bool { endpoint.scheme?.lowercased() == "https" }

    /// The same account seen from another AWS region: S3 answers a bucket of another region only at that region's host.
    func moved(to region: String) -> S3Location {
        guard service == .aws, let address = service.endpoint(region: region), let components = URLComponents(string: address) else { return self }
        return S3Location(service: service, endpoint: components, region: region, bucket: bucket, addressing: addressing)
    }

    /// A bucket can go in the host name only if it is a valid DNS label, and only without dots over TLS: the
    /// wildcard certificate covers one level, and `my.bucket.s3…` would fail validation.
    nonisolated static func fitsInHost(_ bucket: String, secure: Bool) -> Bool {
        guard (3...63).contains(bucket.count), !(secure && bucket.contains(".")) else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.")
        return bucket.allSatisfy(allowed.contains) && bucket.first != "-" && bucket.last != "-"
    }

    func usesPathStyle(for bucket: String) -> Bool {
        switch addressing {
        case .path: return true
        case .virtual: return !Self.fitsInHost(bucket, secure: isSecure)
        case .automatic: return service.prefersPathStyle || !Self.fitsInHost(bucket, secure: isSecure)
        }
    }

    /// The URL of `key` in `bucket`, or of the service itself when there is no bucket (ListBuckets). The key is
    /// encoded with S3's own rules here, so the path that is sent is the one that was signed.
    func url(bucket: String?, key: String = "", query: [(String, String?)] = []) throws -> URL {
        var components = URLComponents()
        components.scheme = endpoint.scheme
        components.host = endpoint.host
        components.port = endpoint.port
        var path = endpoint.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        if let bucket {
            if usesPathStyle(for: bucket) { path += "/" + S3Signer.encode(bucket) }
            else { components.host = bucket + "." + (endpoint.host ?? "") }
        }
        path += "/" + S3Signer.encode(key, slash: true)
        components.percentEncodedPath = path
        if !query.isEmpty {
            components.percentEncodedQuery = query.map { name, value in
                S3Signer.encode(name) + (value.map { "=" + S3Signer.encode($0) } ?? "")
            }.joined(separator: "&")
        }
        guard let url = components.url else { throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor.")) }
        return url
    }
}
