import Foundation
import CryptoKit
import Security

/// Why a vault could not be opened or read. The messages are what the person sees, so they say what to do.
enum CryptomatorError: LocalizedError, Equatable {
    case invalidPassphrase
    case notAVault
    case malformed(String)
    case unsupported(String)
    /// A name, a header or a chunk failed authentication: the bytes are damaged or were changed by someone without the key.
    case unauthentic(String)
    case locked

    var errorDescription: String? {
        switch self {
        case .invalidPassphrase: return L("La contraseña de la bóveda no es correcta.")
        case .notAVault: return L("Esta carpeta no es una bóveda de Cryptomator: le faltan vault.cryptomator o masterkey.cryptomator.")
        case .malformed(let what): return L("La bóveda está dañada: \(what)")
        case .unsupported(let what): return L("Esta bóveda no se puede abrir desde iCloudy: \(what)")
        case .unauthentic(let name): return L("«\(name)» no se pudo descifrar: el contenido cifrado está dañado o alguien lo ha modificado. No se ha guardado nada.")
        case .locked: return L("La bóveda está bloqueada. Desbloquéala para seguir.")
        }
    }
}

/// The two 256-bit keys of a vault. `raw` is their concatenation, encryption key first, which is what signs the
/// vault configuration.
struct CryptomatorMasterkey: Equatable, Sendable {
    let encryptionKey: [UInt8]
    let macKey: [UInt8]
    var raw: [UInt8] { encryptionKey + macKey }

    static func random() throws -> CryptomatorMasterkey {
        CryptomatorMasterkey(encryptionKey: try CryptomatorRandom.bytes(32), macKey: try CryptomatorRandom.bytes(32))
    }
}

enum CryptomatorRandom {
    static func bytes(_ count: Int) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
            throw CryptomatorError.malformed(L("el generador de números aleatorios del sistema no respondió."))
        }
        return bytes
    }
}

/// `masterkey.cryptomator`: both masterkeys wrapped (RFC 3394) with a key derived from the passphrase by scrypt,
/// plus an HMAC of the legacy version number. Field names and meanings follow the published format exactly.
struct CryptomatorMasterkeyFile: Codable, Equatable {
    var version: Int
    var scryptSalt: String
    var scryptCostParam: Int
    var scryptBlockSize: Int
    var primaryMasterKey: String
    var hmacMasterKey: String
    var versionMac: String

    /// Vault format 8 keeps the old version field for compatibility and always writes 999 there.
    static let legacyVersion = 999
    static let defaultCostParam = 32768
    static let defaultBlockSize = 8
    static let saltLength = 8

    static func decode(_ data: Data) throws -> CryptomatorMasterkeyFile {
        do { return try JSONDecoder().decode(CryptomatorMasterkeyFile.self, from: data) }
        catch { throw CryptomatorError.malformed(L("masterkey.cryptomator no se puede leer.")) }
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Cryptomator encodes the passphrase as UTF-8 in Normalization Form C, so the same characters typed on another
    /// keyboard derive the same key.
    static func passphraseBytes(_ passphrase: String) -> [UInt8] { Array(passphrase.precomposedStringWithCanonicalMapping.utf8) }

    static func lock(_ masterkey: CryptomatorMasterkey, passphrase: String, version: Int = legacyVersion,
                     costParam: Int = defaultCostParam, salt suppliedSalt: [UInt8]? = nil) throws -> CryptomatorMasterkeyFile {
        let salt = try suppliedSalt ?? CryptomatorRandom.bytes(saltLength)
        let kek = try Scrypt.derive(password: passphraseBytes(passphrase), salt: salt, n: costParam, r: defaultBlockSize, p: 1, length: 32)
        return CryptomatorMasterkeyFile(version: version, scryptSalt: Data(salt).base64EncodedString(),
                                        scryptCostParam: costParam, scryptBlockSize: defaultBlockSize,
                                        primaryMasterKey: Data(try AESModes.wrap(masterkey.encryptionKey, kek: kek)).base64EncodedString(),
                                        hmacMasterKey: Data(try AESModes.wrap(masterkey.macKey, kek: kek)).base64EncodedString(),
                                        versionMac: Data(versionMAC(version, macKey: masterkey.macKey)).base64EncodedString())
    }

    /// HMAC-SHA256 of the version as a 32-bit big-endian integer, keyed with the MAC masterkey.
    static func versionMAC(_ version: Int, macKey: [UInt8]) -> [UInt8] {
        let bytes = withUnsafeBytes(of: UInt32(truncatingIfNeeded: version).bigEndian, Array.init)
        return Array(HMAC<SHA256>.authenticationCode(for: bytes, using: SymmetricKey(data: macKey)))
    }

    func deriveKEK(passphrase: String) throws -> [UInt8] {
        guard let salt = Data(base64Encoded: scryptSalt) else { throw CryptomatorError.malformed(L("la sal de scrypt no es Base64.")) }
        do {
            return try Scrypt.derive(password: Self.passphraseBytes(passphrase), salt: [UInt8](salt), n: scryptCostParam,
                                     r: scryptBlockSize, p: 1, length: 32)
        } catch {
            throw CryptomatorError.unsupported(L("los parámetros de scrypt (N=\(scryptCostParam), r=\(scryptBlockSize)) no son válidos o piden demasiada memoria."))
        }
    }

    func unlock(passphrase: String) throws -> CryptomatorMasterkey { try unlock(kek: deriveKEK(passphrase: passphrase)) }

    func unlock(kek: [UInt8]) throws -> CryptomatorMasterkey {
        guard let wrappedEncryption = Data(base64Encoded: primaryMasterKey) else { throw CryptomatorError.malformed(L("primaryMasterKey no es Base64.")) }
        guard let wrappedMAC = Data(base64Encoded: hmacMasterKey) else { throw CryptomatorError.malformed(L("hmacMasterKey no es Base64.")) }
        let encryption: [UInt8], mac: [UInt8]
        do {
            encryption = try AESModes.unwrap([UInt8](wrappedEncryption), kek: kek)
            mac = try AESModes.unwrap([UInt8](wrappedMAC), kek: kek)
        } catch AESModes.Failure.unauthentic {
            throw CryptomatorError.invalidPassphrase
        } catch { throw CryptomatorError.malformed(L("las claves envueltas no tienen la longitud esperada.")) }
        guard encryption.count == 32, mac.count == 32 else { throw CryptomatorError.malformed(L("las claves envueltas no tienen la longitud esperada.")) }
        guard let stored = Data(base64Encoded: versionMac), stored.count == 32 else { throw CryptomatorError.malformed(L("versionMac no es Base64.")) }
        // A correct key with a wrong MAC means someone changed the version field: refuse instead of guessing.
        guard AESModes.constantTimeEqual(Self.versionMAC(version, macKey: mac), [UInt8](stored)) else {
            throw CryptomatorError.malformed(L("la versión de masterkey.cryptomator no coincide con su firma."))
        }
        return CryptomatorMasterkey(encryptionKey: encryption, macKey: mac)
    }
}

/// How file contents are encrypted. Names use AES-SIV either way.
enum CryptomatorCipherCombo: String, Sendable {
    /// AES-GCM chunks, the default since Cryptomator 1.7.
    case sivGCM = "SIV_GCM"
    /// AES-CTR with HMAC-SHA256, what vaults created with Cryptomator 1.6 use.
    case sivCTRMAC = "SIV_CTRMAC"
}

/// `vault.cryptomator`: a JWT signed with the raw masterkey that names the format, the content cipher and the
/// name length at which names are shortened.
struct CryptomatorVaultConfig: Equatable {
    static let format = 8
    static let masterkeyKeyIDPrefix = "masterkeyfile:"
    var keyID: String
    var format: Int
    var shorteningThreshold: Int
    var jti: String
    var cipherCombo: CryptomatorCipherCombo

    static func new(cipherCombo: CryptomatorCipherCombo = .sivGCM) -> CryptomatorVaultConfig {
        CryptomatorVaultConfig(keyID: masterkeyKeyIDPrefix + "masterkey.cryptomator", format: format, shorteningThreshold: 220,
                               jti: UUID().uuidString.lowercased(), cipherCombo: cipherCombo)
    }

    /// The file the masterkey lives in, read from the `kid` header. Vaults whose key comes from Cryptomator Hub
    /// or anywhere else are refused here, before any passphrase is asked for.
    var masterkeyFileName: String? {
        guard keyID.hasPrefix(Self.masterkeyKeyIDPrefix) else { return nil }
        let name = String(keyID.dropFirst(Self.masterkeyKeyIDPrefix.count))
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else { return nil }
        return name
    }

    /// The header and claims without checking the signature: step one of opening, which only says which key to load.
    static func unverifiedKeyID(_ token: String) throws -> String {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let headerBytes = CryptomatorEncoding.base64urlDecode(String(parts[0])),
              let header = try? JSONSerialization.jsonObject(with: Data(headerBytes)) as? [String: Any] else {
            throw CryptomatorError.malformed(L("vault.cryptomator no es un JWT válido."))
        }
        guard let kid = header["kid"] as? String else { throw CryptomatorError.malformed(L("vault.cryptomator no dice dónde está la clave.")) }
        return kid
    }

    /// Checks the signature with the raw masterkey, then the claims. HS384 and HS512 are accepted because current
    /// Cryptomator versions accept them; `none` and anything asymmetric are not.
    static func verify(_ token: String, rawKey: [UInt8]) throws -> CryptomatorVaultConfig {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, let headerBytes = CryptomatorEncoding.base64urlDecode(parts[0]),
              let payloadBytes = CryptomatorEncoding.base64urlDecode(parts[1]),
              let signature = CryptomatorEncoding.base64urlDecode(parts[2]),
              let header = try? JSONSerialization.jsonObject(with: Data(headerBytes)) as? [String: Any],
              let payload = try? JSONSerialization.jsonObject(with: Data(payloadBytes)) as? [String: Any] else {
            throw CryptomatorError.malformed(L("vault.cryptomator no es un JWT válido."))
        }
        let signed = Array((parts[0] + "." + parts[1]).utf8)
        let key = SymmetricKey(data: rawKey)
        let expected: [UInt8]
        switch header["alg"] as? String {
        case "HS256": expected = Array(HMAC<SHA256>.authenticationCode(for: signed, using: key))
        case "HS384": expected = Array(HMAC<SHA384>.authenticationCode(for: signed, using: key))
        case "HS512": expected = Array(HMAC<SHA512>.authenticationCode(for: signed, using: key))
        default: throw CryptomatorError.unsupported(L("vault.cryptomator usa una firma que Cryptomator no admite."))
        }
        guard AESModes.constantTimeEqual(expected, signature) else {
            throw CryptomatorError.malformed(L("la firma de vault.cryptomator no corresponde a esta clave."))
        }
        guard let format = payload["format"] as? Int, format == Self.format else {
            throw CryptomatorError.unsupported(L("solo se admite el formato 8 de Cryptomator."))
        }
        guard let comboName = payload["cipherCombo"] as? String, let combo = CryptomatorCipherCombo(rawValue: comboName) else {
            throw CryptomatorError.unsupported(L("el cifrado de contenido de esta bóveda no es SIV_GCM ni SIV_CTRMAC."))
        }
        let threshold = payload["shorteningThreshold"] as? Int ?? 220
        guard threshold >= 36 else { throw CryptomatorError.malformed(L("el umbral de acortamiento de nombres no es válido.")) }
        return CryptomatorVaultConfig(keyID: header["kid"] as? String ?? "", format: format, shorteningThreshold: threshold,
                                      jti: payload["jti"] as? String ?? "", cipherCombo: combo)
    }

    /// HS256-signed, with the claims in the order Cryptomator writes them.
    func token(rawKey: [UInt8]) throws -> String {
        func json(_ object: [(String, Any)]) throws -> String {
            let members = try object.map { key, value -> String in
                let encodedKey = String(decoding: try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
                let encodedValue = String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes]), as: UTF8.self)
                return encodedKey + ":" + encodedValue
            }
            return "{" + members.joined(separator: ",") + "}"
        }
        let header = try json([("kid", keyID), ("typ", "JWT"), ("alg", "HS256")])
        let payload = try json([("format", format), ("shorteningThreshold", shorteningThreshold), ("jti", jti), ("cipherCombo", cipherCombo.rawValue)])
        let unsigned = CryptomatorEncoding.base64url(Array(header.utf8)).replacingOccurrences(of: "=", with: "") + "." +
            CryptomatorEncoding.base64url(Array(payload.utf8)).replacingOccurrences(of: "=", with: "")
        let signature = HMAC<SHA256>.authenticationCode(for: Array(unsigned.utf8), using: SymmetricKey(data: rawKey))
        return unsigned + "." + CryptomatorEncoding.base64url(Array(signature)).replacingOccurrences(of: "=", with: "")
    }
}
