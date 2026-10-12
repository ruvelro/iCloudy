import Foundation
import CryptoKit
import CommonCrypto

/// A private key to sign in to an SSH server with, read from the file `ssh-keygen` writes: the OpenSSH format, which
/// every version since 7.8 uses by default. Ed25519, ECDSA on the three NIST curves and RSA, with or without a
/// passphrase. Keys in the older PEM format are recognised and refused with the command that converts them.
struct SSHPrivateKey: Sendable {
    enum Kind: Sendable {
        case ed25519(Curve25519.Signing.PrivateKey)
        case p256(P256.Signing.PrivateKey)
        case p384(P384.Signing.PrivateKey)
        case p521(P521.Signing.PrivateKey)
        /// Modulus and private exponent, big-endian. Signing is one modular exponentiation.
        case rsa(modulus: Data, exponent: Data)
    }
    let kind: Kind
    /// The public key as the server stores it in `authorized_keys`, in its wire form.
    let publicBlob: Data
    let comment: String

    /// The name the signature goes under in the sign-in request. RSA signs with SHA-256: SHA-1 signatures are refused
    /// by every OpenSSH since 8.8.
    var algorithm: String {
        switch kind {
        case .ed25519: return "ssh-ed25519"
        case .p256: return "ecdsa-sha2-nistp256"
        case .p384: return "ecdsa-sha2-nistp384"
        case .p521: return "ecdsa-sha2-nistp521"
        case .rsa: return "rsa-sha2-256"
        }
    }
    var fingerprint: String { SSHHostKey.fingerprint(publicBlob) }

    enum Problem: LocalizedError, Equatable {
        case notOpenSSH, legacyPEM, needsPassphrase, wrongPassphrase, unsupported(String), damaged
        var errorDescription: String? {
            switch self {
            case .notOpenSSH: return L("Ese archivo no es una clave privada de SSH.")
            case .legacyPEM: return L("Esa clave está en el formato PEM antiguo. Conviértela al de OpenSSH con «ssh-keygen -p -f» seguido de la ruta de la clave, y vuelve a elegirla.")
            case .needsPassphrase: return L("Esa clave está protegida con una frase. Escríbela para usarla.")
            case .wrongPassphrase: return L("La frase de la clave SSH no es correcta.")
            case .unsupported(let what): return L("iCloudy todavía no admite claves SSH con \(what).")
            case .damaged: return L("La clave SSH está dañada o incompleta.")
            }
        }
    }

    static func parse(_ text: String, passphrase: String) throws -> SSHPrivateKey {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let begin = "-----BEGIN OPENSSH PRIVATE KEY-----", end = "-----END OPENSSH PRIVATE KEY-----"
        guard trimmed.hasPrefix(begin), let tail = trimmed.range(of: end) else {
            if trimmed.hasPrefix("-----BEGIN") && trimmed.contains("PRIVATE KEY-----") { throw Problem.legacyPEM }
            throw Problem.notOpenSSH
        }
        let body = trimmed[trimmed.index(trimmed.startIndex, offsetBy: begin.count)..<tail.lowerBound].filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: String(body)) else { throw Problem.damaged }
        // A passphrase with accents can reach `ssh-keygen` composed or decomposed, depending on what typed it; the
        // bytes differ, and so does the key they derive. Both forms are tried before calling it wrong.
        let forms = [passphrase.precomposedStringWithCanonicalMapping, passphrase.decomposedStringWithCanonicalMapping, passphrase]
        // Compared as bytes: Swift calls the two forms equal strings, which is exactly the difference that matters here.
        var tried: Set<Data> = []
        var lastProblem = Problem.wrongPassphrase
        for form in forms where tried.insert(Data(form.utf8)).inserted {
            do { return try parse(data, passphrase: form) }
            catch Problem.wrongPassphrase { lastProblem = .wrongPassphrase; continue }
        }
        throw lastProblem
    }

    private static let magic = Data("openssh-key-v1\0".utf8)

    static func parse(_ data: Data, passphrase: String) throws -> SSHPrivateKey {
        guard data.starts(with: magic) else { throw Problem.notOpenSSH }
        do {
            var reader = SSHReader(Data(data.dropFirst(magic.count)))
            let cipher = try reader.text(), kdf = try reader.text()
            var options = SSHReader(try reader.string())
            guard try reader.uint32() == 1 else { throw Problem.unsupported(L("varias claves en un archivo")) }
            let publicBlob = try reader.string()
            var sealed = try reader.string()
            let tag = cipher == "aes256-gcm@openssh.com" ? try reader.bytes(16) : Data()

            if cipher != "none" {
                guard kdf == "bcrypt" else { throw Problem.unsupported(L("la derivación «\(kdf)»")) }
                guard !passphrase.isEmpty else { throw Problem.needsPassphrase }
                let salt = try options.string(), rounds = Int(try options.uint32())
                let (keyLength, ivLength) = try parameters(cipher)
                let material = try BCryptPBKDF.derive(password: Data(passphrase.utf8), salt: salt, length: keyLength + ivLength, rounds: rounds)
                sealed = try decrypt(sealed, cipher: cipher, key: material.prefix(keyLength), iv: material.suffix(ivLength), tag: tag)
            }

            var secret = SSHReader(sealed)
            // Two copies of one random number: if they differ, the passphrase opened nothing.
            guard try secret.uint32() == (try secret.uint32()) else { throw Problem.wrongPassphrase }
            let type = try secret.text()
            let kind: Kind
            switch type {
            case "ssh-ed25519":
                _ = try secret.string()
                let both = try secret.string()
                guard both.count == 64 else { throw Problem.damaged }
                kind = .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: both.prefix(32)))
            case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
                _ = try secret.text(); _ = try secret.string()
                let scalar = try secret.mpint()
                switch type {
                case "ecdsa-sha2-nistp256": kind = .p256(try P256.Signing.PrivateKey(rawRepresentation: pad(scalar, to: 32)))
                case "ecdsa-sha2-nistp384": kind = .p384(try P384.Signing.PrivateKey(rawRepresentation: pad(scalar, to: 48)))
                default: kind = .p521(try P521.Signing.PrivateKey(rawRepresentation: pad(scalar, to: 66)))
                }
            case "ssh-rsa":
                let modulus = try secret.mpint()
                _ = try secret.mpint()
                let exponent = try secret.mpint()
                _ = try secret.mpint(); _ = try secret.mpint(); _ = try secret.mpint()
                guard modulus.count >= 128, modulus.last.map({ $0 & 1 == 1 }) == true else { throw Problem.unsupported(L("un módulo RSA de menos de 1024 bits")) }
                kind = .rsa(modulus: modulus, exponent: exponent)
            default:
                throw Problem.unsupported(L("el tipo «\(type)»"))
            }
            let comment = (try? secret.text()) ?? ""
            return SSHPrivateKey(kind: kind, publicBlob: publicBlob, comment: comment)
        } catch let problem as Problem {
            throw problem
        } catch is SSHReader.Malformed {
            throw cipher(of: data) == "none" ? Problem.damaged : Problem.wrongPassphrase
        } catch {
            throw Problem.damaged
        }
    }

    /// Only to tell a damaged file from a wrong passphrase when the inner reading fails.
    private static func cipher(of data: Data) -> String? {
        var reader = SSHReader(Data(data.dropFirst(magic.count)))
        return try? reader.text()
    }

    private static func parameters(_ cipher: String) throws -> (key: Int, iv: Int) {
        switch cipher {
        case "aes256-ctr", "aes256-cbc": return (32, 16)
        case "aes192-ctr", "aes192-cbc": return (24, 16)
        case "aes128-ctr", "aes128-cbc": return (16, 16)
        case "aes256-gcm@openssh.com": return (32, 12)
        default: throw Problem.unsupported(L("el cifrado «\(cipher)»"))
        }
    }

    private static func decrypt(_ data: Data, cipher: String, key: Data, iv: Data, tag: Data) throws -> Data {
        if cipher == "aes256-gcm@openssh.com" {
            do {
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: iv), ciphertext: data, tag: tag)
                return try AES.GCM.open(box, using: SymmetricKey(data: key))
            } catch { throw Problem.wrongPassphrase }
        }
        guard data.count % kCCBlockSizeAES128 == 0 else { throw Problem.damaged }
        let mode = cipher.hasSuffix("-ctr") ? CCMode(kCCModeCTR) : CCMode(kCCModeCBC)
        var reference: CCCryptorRef?
        let created = key.withUnsafeBytes { key in
            iv.withUnsafeBytes { iv in
                CCCryptorCreateWithMode(CCOperation(kCCDecrypt), mode, CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding),
                                        iv.baseAddress, key.baseAddress, key.count, nil, 0, 0,
                                        mode == CCMode(kCCModeCTR) ? CCModeOptions(kCCModeOptionCTR_BE) : 0, &reference)
            }
        }
        guard created == kCCSuccess, let reference else { throw Problem.damaged }
        defer { CCCryptorRelease(reference) }
        var output = Data(count: data.count)
        var moved = 0
        let status = output.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(reference, input.baseAddress, data.count, output.baseAddress, output.count, &moved)
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw Problem.damaged }
        return output
    }

    private static func pad(_ value: Data, to length: Int) -> Data {
        value.count >= length ? Data(value.suffix(length)) : Data(repeating: 0, count: length - value.count) + value
    }

    // MARK: - Signing

    /// The signature blob for `data`, as SSH carries it: the algorithm's name, then the signature in its own encoding.
    func sign(_ data: Data) throws -> Data {
        var writer = SSHWriter()
        writer.string(algorithm)
        switch kind {
        case .ed25519(let key):
            writer.string(try key.signature(for: data))
        case .p256(let key):
            writer.string(Self.ecdsa(try key.signature(for: data).rawRepresentation))
        case .p384(let key):
            writer.string(Self.ecdsa(try key.signature(for: data).rawRepresentation))
        case .p521(let key):
            writer.string(Self.ecdsa(try key.signature(for: data).rawRepresentation))
        case .rsa(let modulus, let exponent):
            writer.string(try Self.rsaSHA256(data, modulus: modulus, exponent: exponent))
        }
        return writer.data
    }

    /// r and s, each an mpint, inside the signature string (RFC 5656 §3.1.2).
    private static func ecdsa(_ raw: Data) -> Data {
        var inner = SSHWriter()
        inner.mpint(raw.prefix(raw.count / 2))
        inner.mpint(raw.suffix(raw.count / 2))
        return inner.data
    }

    /// RSASSA-PKCS1-v1_5 with SHA-256 (RFC 8017 §8.2), computed directly: the padded digest raised to the private
    /// exponent modulo n. Security.framework would need the CRT parameters, which take a division to compute.
    static func rsaSHA256(_ data: Data, modulus: Data, exponent: Data) throws -> Data {
        let digestInfo = Data([0x30, 0x31, 0x30, 0x0D, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20])
            + Data(SHA256.hash(data: data))
        let length = modulus.count
        guard length >= digestInfo.count + 11, let montgomery = MegaMontgomery(modulus: MegaBigInt(modulus)) else { throw Problem.damaged }
        let encoded = Data([0x00, 0x01]) + Data(repeating: 0xFF, count: length - digestInfo.count - 3) + Data([0x00]) + digestInfo
        let signature = montgomery.power(base: MegaBigInt(encoded), exponent: MegaBigInt(exponent)).data
        return pad(signature, to: length)
    }
}

/// What an SFTP account keeps beside its password when it signs in with a key: the key file as written and its
/// passphrase, both in the Keychain entry of the account, never on disk.
struct SFTPKeyMaterial: Codable, Equatable {
    var key: String
    var passphrase: String

    static func decode(_ secret: String) -> SFTPKeyMaterial? {
        guard !secret.isEmpty else { return nil }
        return try? JSONDecoder().decode(SFTPKeyMaterial.self, from: Data(secret.utf8))
    }
    var encoded: String { (try? JSONEncoder().encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "" }

    /// Reading a protected key runs bcrypt, which takes a moment on purpose; it never runs on the main thread.
    func open() async throws -> SSHPrivateKey {
        let key = key, passphrase = passphrase
        return try await blockingIO { try SSHPrivateKey.parse(key, passphrase: passphrase) }
    }
}

extension Result {
    var failure: Failure? { if case .failure(let error) = self { return error } else { return nil } }
}
