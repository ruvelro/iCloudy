import Foundation
import CryptoKit

/// The two halves of an S3 access key. The secret never travels: it only derives the key each request is signed with.
struct S3Keys: Equatable, Sendable {
    let accessKey: String
    let secretKey: String
}

/// AWS Signature Version 4, written against the specification rather than an SDK, with S3's own rules: paths are
/// encoded once (other services encode them twice), `/` survives in the path but not in query values, and the payload
/// hash is a header of its own that the server checks against the body.
///
/// Everything here is a pure function of its inputs, the clock included, so the official test vectors can be replayed
/// byte for byte.
enum S3Signer {
    static let algorithm = "AWS4-HMAC-SHA256"
    /// What a streamed body declares instead of its hash. Only acceptable over TLS, which protects the body instead.
    static let unsignedPayload = "UNSIGNED-PAYLOAD"
    /// SHA-256 of nothing: the payload hash of every GET, HEAD and DELETE.
    static let emptyPayloadHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    /// SigV4 refuses longer presigned URLs: a week is the most any link can live.
    static let maximumPresignedLifetime = 7 * 24 * 3600

    private static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// RFC 3986 encoding the way S3 wants it: every byte but the unreserved ones, as uppercase `%XX` of its UTF-8, and
    /// `/` left alone only when `slash` says so (object keys in a path; never in a query value).
    nonisolated static func encode(_ value: String, slash: Bool = false) -> String {
        var allowed = unreserved
        if slash { allowed.insert("/") }
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    nonisolated static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func sha256Hex(_ data: Data) -> String { hex(SHA256.hash(data: data)) }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()
    /// `20130524T000000Z`: the timestamp of `x-amz-date` and of the string to sign.
    nonisolated static func timestamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    // MARK: - Canonical request

    /// The path as S3 reads it: each segment decoded and encoded again once, so a key typed with or without its
    /// escapes signs the same way.
    nonisolated static func canonicalURI(_ url: URL) -> String {
        let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        guard !raw.isEmpty else { return "/" }
        return raw.split(separator: "/", omittingEmptySubsequences: false)
            .map { segment in encode(String(segment).removingPercentEncoding ?? String(segment)) }
            .joined(separator: "/")
    }

    /// Query parameters encoded, then sorted by name and value. A parameter with no value (`?uploads`) signs as `uploads=`.
    nonisolated static func canonicalQuery(_ url: URL) -> String {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedQueryItems ?? []
        var pairs: [(name: String, value: String)] = []
        for item in items {
            let value = item.value.map { $0.removingPercentEncoding ?? $0 } ?? ""
            pairs.append((encode(item.name.removingPercentEncoding ?? item.name), encode(value)))
        }
        pairs.sort { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        return pairs.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    /// The Host header as the request will carry it: the port only when the address names one.
    nonisolated static func hostHeader(_ url: URL) -> String {
        let host = url.host ?? ""
        return url.port.map { host + ":" + String($0) } ?? host
    }

    /// Lowercased names, values trimmed with inner runs of spaces folded, sorted by name. `host` is always signed.
    nonisolated static func canonicalHeaders(_ url: URL, headers: [String: String]) -> (canonical: String, signed: String) {
        var folded: [String: String] = ["host": hostHeader(url)]
        for (name, value) in headers {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            folded[name.lowercased()] = trimmed
        }
        let names = folded.keys.sorted()
        return (names.map { "\($0):\(folded[$0]!)\n" }.joined(), names.joined(separator: ";"))
    }

    nonisolated static func canonicalRequest(method: String, url: URL, headers: [String: String], payloadHash: String) -> (request: String, signedHeaders: String) {
        let (canonical, signed) = canonicalHeaders(url, headers: headers)
        let request = [method.uppercased(), canonicalURI(url), canonicalQuery(url), canonical, signed, payloadHash].joined(separator: "\n")
        return (request, signed)
    }

    // MARK: - Signature

    nonisolated static func scope(date: Date, region: String, service: String) -> String {
        "\(String(timestamp(date).prefix(8)))/\(region)/\(service)/aws4_request"
    }

    nonisolated static func stringToSign(canonicalRequest: String, date: Date, region: String, service: String) -> String {
        [algorithm, timestamp(date), scope(date: date, region: region, service: service),
         sha256Hex(Data(canonicalRequest.utf8))].joined(separator: "\n")
    }

    private nonisolated static func hmac(_ key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    /// `kSigning`: the secret folded through the date, the region, the service and the terminator, in that order.
    nonisolated static func signingKey(secret: String, day: String, region: String, service: String) -> Data {
        let date = hmac(Data(("AWS4" + secret).utf8), day)
        return hmac(hmac(hmac(date, region), service), "aws4_request")
    }

    nonisolated static func signature(stringToSign: String, keys: S3Keys, date: Date, region: String, service: String) -> String {
        let key = signingKey(secret: keys.secretKey, day: String(timestamp(date).prefix(8)), region: region, service: service)
        return hex(hmac(key, stringToSign))
    }

    /// The `Authorization` header for a request whose other headers are exactly `headers` (`x-amz-date` among them).
    /// Every header passed in is signed, so nothing a proxy might rewrite should be.
    nonisolated static func authorization(method: String, url: URL, headers: [String: String], payloadHash: String,
                                          keys: S3Keys, region: String, service: String = "s3", date: Date) -> String {
        let (request, signed) = canonicalRequest(method: method, url: url, headers: headers, payloadHash: payloadHash)
        let toSign = stringToSign(canonicalRequest: request, date: date, region: region, service: service)
        let signature = signature(stringToSign: toSign, keys: keys, date: date, region: region, service: service)
        return "\(algorithm) Credential=\(keys.accessKey)/\(scope(date: date, region: region, service: service)), SignedHeaders=\(signed), Signature=\(signature)"
    }

    /// A URL that carries its own signature in the query and works for anyone who has it until it expires. Only the
    /// host is signed, and the body is declared unsigned, which is what a plain GET from a browser sends.
    nonisolated static func presign(url: URL, method: String = "GET", keys: S3Keys, region: String, service: String = "s3",
                                    date: Date, expires: Int) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let lifetime = min(max(1, expires), maximumPresignedLifetime)
        var items = components.percentEncodedQueryItems ?? []
        items += [URLQueryItem(name: "X-Amz-Algorithm", value: algorithm),
                  URLQueryItem(name: "X-Amz-Credential", value: encode(keys.accessKey + "/" + scope(date: date, region: region, service: service))),
                  URLQueryItem(name: "X-Amz-Date", value: timestamp(date)),
                  URLQueryItem(name: "X-Amz-Expires", value: String(lifetime)),
                  URLQueryItem(name: "X-Amz-SignedHeaders", value: "host")]
        components.percentEncodedQueryItems = items
        guard let unsigned = components.url else { return nil }
        // The query that goes out is the canonical one, so what the server rebuilds is what was signed.
        let query = canonicalQuery(unsigned)
        let (request, _) = canonicalRequest(method: method, url: unsigned, headers: [:], payloadHash: unsignedPayload)
        let toSign = stringToSign(canonicalRequest: request, date: date, region: region, service: service)
        components.percentEncodedQuery = query + "&X-Amz-Signature=" + signature(stringToSign: toSign, keys: keys, date: date, region: region, service: service)
        return components.url
    }
}
