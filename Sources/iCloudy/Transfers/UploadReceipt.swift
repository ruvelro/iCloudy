import Foundation
import CryptoKit

enum UploadVerification: String, Codable { case verified, unavailable }
struct UploadReceipt {
    let remoteID: String?
    let verification: UploadVerification
}

/// Incremental digests over the uploaded blocks. Drive reports `md5Checksum`; Graph reports `sha256Hash` or `sha1Hash`
/// (personal accounts) and `quickXorHash` (business). QuickXorHash is not implemented, so business uploads stay
/// "unavailable" rather than risking a false mismatch.
struct UploadHasher {
    private var md5 = Insecure.MD5()
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    private let cloud: Cloud
    init(cloud: Cloud) { self.cloud = cloud }
    mutating func update(_ data: Data) {
        if cloud == .google { md5.update(data: data) } else { sha1.update(data: data); sha256.update(data: data) }
    }
    /// Throws when the provider's checksum disagrees: the bytes stored are not the bytes sent.
    func verify(against item: [String: Any], name: String) throws -> UploadVerification {
        let expected: String?, actual: String
        if cloud == .google {
            expected = item["md5Checksum"] as? String
            actual = Self.hex(md5.finalize())
        } else {
            let hashes = (item["file"] as? [String: Any])?["hashes"] as? [String: Any]
            if let sha = hashes?["sha256Hash"] as? String { expected = sha; actual = Self.hex(sha256.finalize()) }
            else { expected = hashes?["sha1Hash"] as? String; actual = Self.hex(sha1.finalize()) }
        }
        guard let expected else { return .unavailable }
        guard expected.lowercased() == actual.lowercased() else {
            throw CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
        }
        return .verified
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}
