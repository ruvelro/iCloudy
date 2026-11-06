import Foundation
import CryptoKit

/// Azure Storage's Shared Key authorization and service SAS, written on CryptoKit. The account key never travels: it
/// signs each request (an HMAC-SHA256 over a canonical description of it) and each link.
/// https://learn.microsoft.com/rest/api/storageservices/authorize-with-shared-key
/// https://learn.microsoft.com/rest/api/storageservices/create-service-sas
enum AzureSigner {
    /// The REST version every request declares and every link is signed for.
    static let version = "2021-08-06"

    /// The string Shared Key signs, for API versions from 2015-02-21: the verb, eleven standard headers (with an empty
    /// Content-Length for an empty body), the `x-ms-` headers and the resource.
    static func stringToSign(method: String, url: URL, headers: [String: String], account: String) -> String {
        let lower = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        func header(_ name: String) -> String { lower[name] ?? "" }
        let length = header("content-length") == "0" ? "" : header("content-length")
        let standard = [method.uppercased(), header("content-encoding"), header("content-language"), length, header("content-md5"),
                        header("content-type"), header("date"), header("if-modified-since"), header("if-match"), header("if-none-match"),
                        header("if-unmodified-since"), header("range")]
        let canonicalHeaders = lower.filter { $0.key.hasPrefix("x-ms-") }
            .map { (key: $0.key, value: $0.value.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.key < $1.key }
            .map { $0.key + ":" + $0.value + "\n" }.joined()
        return standard.joined(separator: "\n") + "\n" + canonicalHeaders + canonicalResource(url: url, account: account)
    }

    /// `/account/path` and then each query parameter, its name lowercased, in order, with its decoded values.
    static func canonicalResource(url: URL, account: String) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? "/"
        var resource = "/" + account + (path.isEmpty ? "/" : path)
        var parameters: [String: [String]] = [:]
        for item in components?.queryItems ?? [] { parameters[item.name.lowercased(), default: []].append(item.value ?? "") }
        for name in parameters.keys.sorted() {
            resource += "\n" + name + ":" + parameters[name]!.sorted().joined(separator: ",")
        }
        return resource
    }

    static func signature(_ text: String, key: Data) -> String {
        Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: SymmetricKey(data: key))).base64EncodedString()
    }

    static func authorization(method: String, url: URL, headers: [String: String], account: String, key: Data) -> String {
        "SharedKey " + account + ":" + signature(stringToSign(method: method, url: url, headers: headers, account: account), key: key)
    }

    static let rfc1123: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter
    }()
    static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A read-only service SAS for one blob, valid from a few minutes ago (clocks differ) until `expiry`, over HTTPS.
    /// The string to sign is the one of versions 2020-12-06 and later, encryption scope included.
    static func blobSAS(account: String, container: String, blob: String, key: Data, start: Date, expiry: Date) -> [URLQueryItem] {
        let permissions = "r", startText = iso8601(start), expiryText = iso8601(expiry)
        let fields = [permissions, startText, expiryText, "/blob/" + account + "/" + container + "/" + blob, "", "", "https", version, "b",
                      "", "", "", "", "", "", ""]
        let signed = signature(fields.joined(separator: "\n"), key: key)
        return [URLQueryItem(name: "sv", value: version), URLQueryItem(name: "spr", value: "https"), URLQueryItem(name: "st", value: startText),
                URLQueryItem(name: "se", value: expiryText), URLQueryItem(name: "sr", value: "b"), URLQueryItem(name: "sp", value: permissions),
                URLQueryItem(name: "sig", value: signed)]
    }

    /// Percent-encoding for a query value: everything but the unreserved characters, so a `+` or `/` of a signature
    /// survives the trip.
    static func encodeQuery(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }
}
