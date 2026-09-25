import Foundation
import CryptoKit
import CommonCrypto
import Security

/// The cryptography of the SSH transport, built only out of what the system already ships: CryptoKit for the key
/// agreement, the signatures, AES-GCM and HMAC; CommonCrypto for AES in counter mode; Security for RSA host keys.
/// Nothing here is a primitive of our own. What is ours is the plumbing RFC 4253 asks for around them, and each piece
/// of that plumbing is checked against published test vectors in `SFTPTests`.
enum SSHAlgorithms {
    /// Preferences, most wanted first. Every server that matters offers at least one of each: OpenSSH since 6.5,
    /// ProFTPD's mod_sftp, Synology, QNAP and the routers built on Dropbear.
    static let kex = ["curve25519-sha256", "curve25519-sha256@libssh.org", "ecdh-sha2-nistp256"]
    static let hostKeys = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "rsa-sha2-512", "rsa-sha2-256"]
    static let ciphers = ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com", "aes256-ctr", "aes128-ctr"]
    static let macs = ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-256"]
    static let compression = ["none"]

    /// RFC 4253 §7.1: the first of the client's names that the server also lists.
    static func negotiate(_ ours: [String], _ theirs: [String]) -> String? {
        ours.first { theirs.contains($0) }
    }
}

/// One direction of the encrypted packet stream: its cipher state, its MAC key and its sequence number.
final class SSHPacketCipher {
    enum Mode {
        case plain
        /// RFC 5647: the length travels in the clear as associated data, the tag closes each packet, and the nonce's
        /// low 64 bits count packets.
        case gcm(key: SymmetricKey, nonce: Data)
        /// AES-CTR with HMAC-SHA-256, either over the ciphertext (`etm`) or, in the older layout, over the plaintext.
        case ctr(cryptor: CCCryptorRef, mac: SymmetricKey, etm: Bool)
    }
    private var mode: Mode
    var sequence: UInt32 = 0
    init(_ mode: Mode = .plain) { self.mode = mode }
    deinit { if case .ctr(let cryptor, _, _) = mode { CCCryptorRelease(cryptor) } }

    static let blockSize = 16
    /// True when the four length bytes are not encrypted, which changes how the padding is counted.
    private var lengthInClear: Bool {
        switch mode {
        case .plain: return false
        case .gcm: return true
        case .ctr(_, _, let etm): return etm
        }
    }
    /// How many bytes must be read before the packet length is known.
    var headLength: Int {
        switch mode {
        case .plain: return 4
        case .gcm: return 4
        case .ctr(_, _, let etm): return etm ? 4 : Self.blockSize
        }
    }
    /// Bytes after the packet: the GCM tag or the MAC.
    var trailerLength: Int {
        switch mode {
        case .plain: return 0
        case .gcm: return 16
        case .ctr: return 32
        }
    }

    static func build(cipher: String, mac: String, key: Data, iv: Data, macKey: Data) throws -> SSHPacketCipher {
        switch cipher {
        case "aes256-gcm@openssh.com", "aes128-gcm@openssh.com":
            return SSHPacketCipher(.gcm(key: SymmetricKey(data: key), nonce: iv.prefix(12)))
        case "aes256-ctr", "aes128-ctr":
            var cryptor: CCCryptorRef?
            let status = key.withUnsafeBytes { keyBytes in
                iv.withUnsafeBytes { ivBytes in
                    CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                            ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
                }
            }
            guard status == kCCSuccess, let cryptor else { throw CloudError.message(L("No se pudo preparar el cifrado de la sesión SSH.")) }
            return SSHPacketCipher(.ctr(cryptor: cryptor, mac: SymmetricKey(data: macKey), etm: mac.hasSuffix("-etm@openssh.com")))
        default:
            throw CloudError.message(L("El servidor SSH no ofrece ningún cifrado que iCloudy conozca."))
        }
    }
    static func keyLength(_ cipher: String) -> Int { cipher.hasPrefix("aes256") ? 32 : 16 }
    static func ivLength(_ cipher: String) -> Int { cipher.hasSuffix("gcm@openssh.com") ? 12 : 16 }

    /// Builds one outgoing packet: length, padding length, payload, random padding, then the tag or MAC.
    func seal(_ payload: Data) throws -> Data {
        defer { sequence &+= 1 }
        // The block alignment covers the encrypted part only, so a length in the clear is left out of the count.
        let counted = (lengthInClear ? 0 : 4) + 1 + payload.count
        var padding = Self.blockSize - counted % Self.blockSize
        if padding < 4 { padding += Self.blockSize }
        var body = SSHWriter()
        body.byte(UInt8(padding))
        body.raw(payload)
        body.raw(Data((0..<padding).map { _ in UInt8.random(in: 0...255) }))
        var lengthField = SSHWriter()
        lengthField.uint32(UInt32(body.data.count))
        switch mode {
        case .plain:
            return lengthField.data + body.data
        case .gcm(let key, let nonce):
            let sealed = try AES.GCM.seal(body.data, using: key, nonce: AES.GCM.Nonce(data: nonce), authenticating: lengthField.data)
            advanceNonce()
            return lengthField.data + sealed.ciphertext + sealed.tag
        case .ctr(let cryptor, let macKey, let etm):
            var sequenceBytes = SSHWriter(); sequenceBytes.uint32(sequence)
            if etm {
                let ciphertext = try Self.crypt(cryptor, body.data)
                let mac = HMAC<SHA256>.authenticationCode(for: sequenceBytes.data + lengthField.data + ciphertext, using: macKey)
                return lengthField.data + ciphertext + Data(mac)
            }
            let mac = HMAC<SHA256>.authenticationCode(for: sequenceBytes.data + lengthField.data + body.data, using: macKey)
            let ciphertext = try Self.crypt(cryptor, lengthField.data + body.data)
            return ciphertext + Data(mac)
        }
    }

    /// Reads the packet length out of the first `headLength` bytes, decrypting them when they are not in the clear.
    /// Returns the length and the head as it must be kept for `open`.
    func packetLength(head: Data) throws -> (length: Int, head: Data) {
        var reader: SSHReader
        var kept = head
        if case .ctr(let cryptor, _, false) = mode { kept = try Self.crypt(cryptor, head) }
        reader = SSHReader(kept)
        let length = Int(try reader.uint32())
        // RFC 4253 allows 35 000 bytes; anything larger is either garbage or a hostile server, and would only be
        // allocated to be thrown away.
        guard length >= 5, length <= 256 * 1024 else { throw SSHReader.Malformed() }
        return (length, kept)
    }
    /// Verifies and decrypts one packet given the head returned above, the rest of the packet and its trailer.
    /// Returns the payload without its padding.
    func open(head: Data, rest: Data, trailer: Data) throws -> Data {
        defer { sequence &+= 1 }
        let lengthField = Data(head.prefix(4))
        var sequenceBytes = SSHWriter(); sequenceBytes.uint32(sequence)
        let body: Data
        switch mode {
        case .plain:
            body = head.dropFirst(4) + rest
        case .gcm(let key, let nonce):
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: rest, tag: trailer)
            body = try AES.GCM.open(box, using: key, authenticating: lengthField)
            advanceNonce()
        case .ctr(let cryptor, let macKey, let etm):
            if etm {
                let expected = HMAC<SHA256>.authenticationCode(for: sequenceBytes.data + lengthField + rest, using: macKey)
                guard Data(expected) == trailer else { throw Tampered() }
                body = try Self.crypt(cryptor, rest)
            } else {
                // The head was already decrypted to learn the length; only the rest is still ciphertext.
                let plain = head.dropFirst(4) + (try Self.crypt(cryptor, rest))
                let expected = HMAC<SHA256>.authenticationCode(for: sequenceBytes.data + lengthField + plain, using: macKey)
                guard Data(expected) == trailer else { throw Tampered() }
                body = plain
            }
        }
        guard let paddingLength = body.first, body.count > Int(paddingLength) else { throw SSHReader.Malformed() }
        return Data(body.dropFirst().dropLast(Int(paddingLength)))
    }
    struct Tampered: LocalizedError {
        var errorDescription: String? { L("La conexión SSH falló la comprobación de integridad: alguien alteró o corrompió los datos en tránsito.") }
    }

    private func advanceNonce() {
        guard case .gcm(let key, var nonce) = mode else { return }
        // The invocation counter is the low 64 bits, incremented as one big-endian number.
        var index = nonce.index(before: nonce.endIndex)
        while index >= nonce.index(nonce.startIndex, offsetBy: 4) {
            nonce[index] &+= 1
            if nonce[index] != 0 { break }
            index = nonce.index(before: index)
        }
        mode = .gcm(key: key, nonce: nonce)
    }
    private static func crypt(_ cryptor: CCCryptorRef, _ input: Data) throws -> Data {
        var output = Data(count: input.count)
        var moved = 0
        let status = input.withUnsafeBytes { inBytes in
            output.withUnsafeMutableBytes { outBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, input.count, outBytes.baseAddress, input.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == input.count else { throw CloudError.message(L("El cifrado de la sesión SSH falló.")) }
        return output
    }
}

enum SSHKeyDerivation {
    /// RFC 4253 §7.2: HASH(K || H || letter || session_id), extended with HASH(K || H || key so far) as needed.
    static func derive(sharedSecret: Data, exchangeHash: Data, letter: Character, sessionID: Data, length: Int) -> Data {
        var k = SSHWriter(); k.mpint(sharedSecret)
        var key = Data(SHA256.hash(data: k.data + exchangeHash + Data(String(letter).utf8) + sessionID))
        while key.count < length { key += Data(SHA256.hash(data: k.data + exchangeHash + key)) }
        return key.prefix(length)
    }
}

/// The server's public key: what it is, how to name it to a person, and whether a signature under it is genuine.
enum SSHHostKey {
    static func type(of blob: Data) -> String {
        var reader = SSHReader(blob)
        return (try? reader.text()) ?? ""
    }
    /// OpenSSH's own spelling: `SHA256:` and the digest in base64 without padding.
    static func fingerprint(_ blob: Data) -> String {
        "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
    struct Unverifiable: LocalizedError {
        let reason: String
        var errorDescription: String? { L("No se pudo comprobar la clave del servidor SSH: \(reason)") }
    }
    /// True when `signature`, which the server made over the exchange hash, was produced with the key in `blob`.
    static func verify(blob: Data, signature: Data, message: Data) throws -> Bool {
        var key = SSHReader(blob)
        let keyType = try key.text()
        var sig = SSHReader(signature)
        let sigType = try sig.text()
        let sigBytes = try sig.string()
        switch keyType {
        case "ssh-ed25519":
            guard sigType == keyType else { return false }
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: try key.string())
            return publicKey.isValidSignature(sigBytes, for: message)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384":
            guard sigType == keyType else { return false }
            _ = try key.text()
            let point = try key.string()
            var parts = SSHReader(sigBytes)
            let r = try parts.mpint(), s = try parts.mpint()
            if keyType.hasSuffix("256") {
                let raw = pad(r, to: 32) + pad(s, to: 32)
                return try P256.Signing.PublicKey(x963Representation: point).isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: message)
            }
            let raw = pad(r, to: 48) + pad(s, to: 48)
            return try P384.Signing.PublicKey(x963Representation: point).isValidSignature(try P384.Signing.ECDSASignature(rawRepresentation: raw), for: message)
        case "ssh-rsa":
            // The key blob says "ssh-rsa" whatever the signature scheme; only rsa-sha2-256 and -512 are accepted,
            // because plain ssh-rsa is SHA-1 and OpenSSH itself stopped offering it in 2021.
            let algorithm: SecKeyAlgorithm
            switch sigType {
            case "rsa-sha2-256": algorithm = .rsaSignatureMessagePKCS1v15SHA256
            case "rsa-sha2-512": algorithm = .rsaSignatureMessagePKCS1v15SHA512
            default: return false
            }
            let e = try key.mpint(), n = try key.mpint()
            let publicKey = try rsaKey(modulus: n, exponent: e)
            var error: Unmanaged<CFError>?
            let valid = SecKeyVerifySignature(publicKey, algorithm, message as CFData, sigBytes as CFData, &error)
            if let error = error?.takeRetainedValue(), (error as Error as NSError).code != Int(errSecVerifyFailed) { throw Unverifiable(reason: (error as Error).localizedDescription) }
            return valid
        default:
            throw Unverifiable(reason: L("tipo de clave \(keyType) desconocido"))
        }
    }
    private static func pad(_ value: Data, to length: Int) -> Data {
        value.count >= length ? Data(value.suffix(length)) : Data(count: length - value.count) + value
    }
    /// Security wants a PKCS#1 `RSAPublicKey`: SEQUENCE { INTEGER n, INTEGER e }.
    static func rsaKey(modulus: Data, exponent: Data) throws -> SecKey {
        func integer(_ value: Data) -> Data {
            var bytes = Data(value.drop { $0 == 0 })
            if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + derLength(bytes.count) + bytes
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + derLength(body.count) + body
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
                                           kSecAttrKeySizeInBits: modulus.drop { $0 == 0 }.count * 8]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw Unverifiable(reason: error.map { ($0.takeRetainedValue() as Error).localizedDescription } ?? L("clave RSA no válida"))
        }
        return key
    }
    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var bytes: [UInt8] = []
        var value = length
        while value > 0 { bytes.insert(UInt8(value & 0xFF), at: 0); value >>= 8 }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }
}

/// The client's half of the key exchange for the algorithms offered above.
enum SSHKeyExchange {
    enum Ephemeral {
        case curve25519(Curve25519.KeyAgreement.PrivateKey)
        case p256(P256.KeyAgreement.PrivateKey)
        var publicBytes: Data {
            switch self {
            case .curve25519(let key): return key.publicKey.rawRepresentation
            case .p256(let key): return key.publicKey.x963Representation
            }
        }
        /// The shared secret K as a magnitude; the caller encodes it as an mpint.
        func sharedSecret(with peer: Data) throws -> Data {
            switch self {
            case .curve25519(let key):
                let secret = try key.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
                return secret.withUnsafeBytes { Data($0) }
            case .p256(let key):
                let secret = try key.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: peer))
                return secret.withUnsafeBytes { Data($0) }
            }
        }
    }
    static func start(_ algorithm: String) throws -> Ephemeral {
        switch algorithm {
        case "curve25519-sha256", "curve25519-sha256@libssh.org": return .curve25519(Curve25519.KeyAgreement.PrivateKey())
        case "ecdh-sha2-nistp256": return .p256(P256.KeyAgreement.PrivateKey())
        default: throw CloudError.message(L("El servidor SSH no ofrece ningún intercambio de claves que iCloudy conozca."))
        }
    }
    /// RFC 5656 §4 / RFC 8731: H = HASH(V_C || V_S || I_C || I_S || K_S || Q_C || Q_S || K).
    static func exchangeHash(clientVersion: String, serverVersion: String, clientKexInit: Data, serverKexInit: Data,
                             hostKey: Data, clientPublic: Data, serverPublic: Data, sharedSecret: Data) -> Data {
        var writer = SSHWriter()
        writer.string(clientVersion); writer.string(serverVersion)
        writer.string(clientKexInit); writer.string(serverKexInit)
        writer.string(hostKey); writer.string(clientPublic); writer.string(serverPublic)
        writer.mpint(sharedSecret)
        return Data(SHA256.hash(data: writer.data))
    }
}
