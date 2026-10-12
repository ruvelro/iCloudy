import XCTest
import CryptoKit
@testable import iCloudy

/// Private keys as `ssh-keygen` writes them, read and used to sign. Every key is made by the system's own
/// `ssh-keygen` for the test, so the format is the real one and nothing secret is checked in.
final class SSHKeyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen"), "ssh-keygen no está disponible")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let folder { try? FileManager.default.removeItem(at: folder) } }

    /// A fresh key: its private file and the public line `authorized_keys` would hold.
    private func generate(_ type: String, bits: Int? = nil, passphrase: String = "", cipher: String? = nil) throws -> (text: String, publicLine: String) {
        let path = folder.appendingPathComponent(UUID().uuidString).path
        var arguments = ["-q", "-t", type, "-N", passphrase, "-C", "prueba@icloudy", "-f", path]
        if let bits { arguments += ["-b", String(bits)] }
        if let cipher { arguments += ["-Z", cipher] }
        // Few rounds keep the test quick; the derivation is the same at any count.
        if !passphrase.isEmpty { arguments += ["-a", "2"] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        try process.run(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return (try String(contentsOfFile: path, encoding: .utf8), try String(contentsOfFile: path + ".pub", encoding: .utf8))
    }

    private func publicBlob(_ line: String) -> Data? { Data(base64Encoded: String(line.split(separator: " ")[1])) }

    private func assertSigns(_ key: SSHPrivateKey, publicLine: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(key.publicBlob, publicBlob(publicLine), "La parte pública es la de authorized_keys", file: file, line: line)
        let message = Data("prueba de firma \(UUID())".utf8)
        let signature = try key.sign(message)
        if case .p521 = key.kind {
            var blob = SSHReader(key.publicBlob); _ = try blob.text(); _ = try blob.text()
            var sig = SSHReader(signature); XCTAssertEqual(try sig.text(), "ecdsa-sha2-nistp521")
            var parts = SSHReader(try sig.string())
            let pad = { (value: Data) in Data(repeating: 0, count: max(0, 66 - value.count)) + value.suffix(66) }
            let raw = pad(try parts.mpint()) + pad(try parts.mpint())
            XCTAssertTrue(try P521.Signing.PublicKey(x963Representation: try blob.string())
                .isValidSignature(try P521.Signing.ECDSASignature(rawRepresentation: raw), for: message), file: file, line: line)
            return
        }
        XCTAssertTrue(try SSHHostKey.verify(blob: key.publicBlob, signature: signature, message: message), "Firma válida", file: file, line: line)
        XCTAssertFalse(try SSHHostKey.verify(blob: key.publicBlob, signature: signature, message: message + Data([1])), file: file, line: line)
    }

    func testKeysWithoutPassphraseOfEveryType() throws {
        for (type, bits) in [("ed25519", nil), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521), ("rsa", 2048)] as [(String, Int?)] {
            let generated = try generate(type, bits: bits)
            let key = try SSHPrivateKey.parse(generated.text, passphrase: "")
            XCTAssertEqual(key.comment, "prueba@icloudy")
            try assertSigns(key, publicLine: generated.publicLine)
        }
    }

    func testAPassphraseProtectedKeyOpensOnlyWithItsPassphrase() throws {
        let generated = try generate("ed25519", passphrase: "correcto caballo batería")
        XCTAssertThrowsError(try SSHPrivateKey.parse(generated.text, passphrase: "")) { XCTAssertEqual($0 as? SSHPrivateKey.Problem, .needsPassphrase) }
        XCTAssertThrowsError(try SSHPrivateKey.parse(generated.text, passphrase: "otra")) { XCTAssertEqual($0 as? SSHPrivateKey.Problem, .wrongPassphrase) }
        try assertSigns(try SSHPrivateKey.parse(generated.text, passphrase: "correcto caballo batería"), publicLine: generated.publicLine)
    }

    func testEncryptedRSAAndECDSAAndTheGCMCipher() throws {
        let rsa = try generate("rsa", bits: 3072, passphrase: "frase")
        try assertSigns(try SSHPrivateKey.parse(rsa.text, passphrase: "frase"), publicLine: rsa.publicLine)
        let ecdsa = try generate("ecdsa", bits: 256, passphrase: "frase", cipher: "aes256-gcm@openssh.com")
        try assertSigns(try SSHPrivateKey.parse(ecdsa.text, passphrase: "frase"), publicLine: ecdsa.publicLine)
        XCTAssertThrowsError(try SSHPrivateKey.parse(ecdsa.text, passphrase: "mala")) { XCTAssertEqual($0 as? SSHPrivateKey.Problem, .wrongPassphrase) }
        let ctr = try generate("ed25519", passphrase: "frase", cipher: "aes128-ctr")
        try assertSigns(try SSHPrivateKey.parse(ctr.text, passphrase: "frase"), publicLine: ctr.publicLine)
    }

    func testOtherFilesAreRefusedWithAReason() {
        XCTAssertThrowsError(try SSHPrivateKey.parse("ssh-ed25519 AAAA prueba", passphrase: "")) { XCTAssertEqual($0 as? SSHPrivateKey.Problem, .notOpenSSH) }
        XCTAssertThrowsError(try SSHPrivateKey.parse("-----BEGIN RSA PRIVATE KEY-----\nMIIB\n-----END RSA PRIVATE KEY-----", passphrase: "")) {
            XCTAssertEqual($0 as? SSHPrivateKey.Problem, .legacyPEM)
        }
        XCTAssertThrowsError(try SSHPrivateKey.parse("-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----", passphrase: ""))
    }

    /// The public test vector of OpenBSD's regression test for bcrypt_pbkdf: "password", "salt", 4 rounds.
    func testBCryptPBKDFMatchesOpenBSD() throws {
        let key = try BCryptPBKDF.derive(password: Data("password".utf8), salt: Data("salt".utf8), length: 32, rounds: 4)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
    }
}
