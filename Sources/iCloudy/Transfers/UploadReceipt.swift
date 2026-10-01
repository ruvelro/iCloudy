import Foundation
import CryptoKit

enum UploadVerification: String, Codable { case verified, unavailable }
struct UploadReceipt {
    let remoteID: String?
    let verification: UploadVerification
}

/// Incremental digests over the uploaded blocks. Drive reports `md5Checksum`; Graph reports `sha256Hash` or
/// `sha1Hash` on some personal accounts and `quickXorHash` on every account, business included, so all three are
/// kept and the strongest one the response lists is compared.
struct UploadHasher {
    private var md5 = Insecure.MD5()
    private var sha1 = Insecure.SHA1()
    private var sha256 = SHA256()
    private var quickXor = QuickXorHash()
    private let cloud: Cloud
    init(cloud: Cloud) { self.cloud = cloud }
    mutating func update(_ data: Data) {
        if cloud == .google { md5.update(data: data) } else { sha1.update(data: data); sha256.update(data: data); quickXor.update(data) }
    }
    /// Throws when the provider's checksum disagrees: the bytes stored are not the bytes sent.
    func verify(against item: [String: Any], name: String) throws -> UploadVerification {
        let matches: Bool
        if cloud == .google {
            guard let expected = item["md5Checksum"] as? String else { return .unavailable }
            matches = expected.lowercased() == Self.hex(md5.finalize())
        } else {
            let hashes = (item["file"] as? [String: Any])?["hashes"] as? [String: Any]
            if let sha = hashes?["sha256Hash"] as? String {
                matches = sha.lowercased() == Self.hex(sha256.finalize())
            } else if let quick = hashes?["quickXorHash"] as? String, !quick.isEmpty {
                // Base64, as Graph spells it; compared as bytes so the spelling of the padding cannot decide.
                matches = Data(base64Encoded: quick, options: .ignoreUnknownCharacters) == quickXor.finalize()
            } else if let sha = hashes?["sha1Hash"] as? String {
                matches = sha.lowercased() == Self.hex(sha1.finalize())
            } else {
                return .unavailable
            }
        }
        guard matches else {
            throw CloudError.message(L("La suma de verificación de «\(name)» no coincide con la que informa el servidor. La copia remota puede estar dañada: revísala o vuelve a subirla."))
        }
        return .verified
    }
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 { digest.map { String(format: "%02x", $0) }.joined() }
}
