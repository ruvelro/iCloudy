import XCTest
import CryptoKit
@testable import iCloudy

/// Every primitive under the vault format, checked against values that do not come from iCloudy: the RFCs that define
/// scrypt, CMAC, SIV and key wrap, and the unit tests Cryptomator publishes for its own libraries (cryptolib-swift's
/// MasterkeyFileTests, CryptorTests, GcmCryptorTests and CtrCryptorTests; cryptofs's VaultConfigTest). If one of these
/// disagreed, a vault written here would not open in Cryptomator, or the other way round.
final class CryptomatorCryptoTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        let clean = hex.filter { $0.isHexDigit }
        var result: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            result.append(UInt8(clean[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
    private func words(_ data: [UInt8]) -> [UInt32] {
        stride(from: 0, to: data.count, by: 4).map { UInt32(data[$0]) | UInt32(data[$0 + 1]) << 8 | UInt32(data[$0 + 2]) << 16 | UInt32(data[$0 + 3]) << 24 }
    }
    private func bytes(words: [UInt32]) -> [UInt8] { words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } } }

    // MARK: - scrypt (RFC 7914)

    func testSalsa20CoreMatchesRFC7914() {
        var state = words(bytes("""
            7e 87 9a 21 4f 3e c9 86 7c a9 40 e6 41 71 8f 26 ba ee 55 5b 8c 61 c1 b5 0d f8 46 11 6d cd 3b 1d
            ee 24 f3 19 df 9b 3d 85 14 12 1e 4b 5a c5 aa 32 76 02 1d 29 09 c7 48 29 ed eb c6 8d b8 b8 c2 5e
            """))
        state.withUnsafeMutableBufferPointer { Scrypt.salsa20_8($0.baseAddress!) }
        XCTAssertEqual(bytes(words: state), bytes("""
            a4 1f 85 9c 66 08 cc 99 3b 81 ca cb 02 0c ef 05 04 4b 21 81 a2 fd 33 7d fd 7b 1c 63 96 68 2f 29
            b4 39 31 68 e3 c9 e6 bc fe 6b c5 b7 a0 6d 96 ba e4 24 cc 10 2c 91 74 5c 24 ad 67 3d c7 61 8f 81
            """))
    }

    func testBlockMixMatchesRFC7914() {
        var state = words(bytes("""
            f7 ce 0b 65 3d 2d 72 a4 10 8c f5 ab e9 12 ff dd 77 76 16 db bb 27 a7 0e 82 04 f3 ae 2d 0f 6f ad
            89 f6 8f 48 11 d1 e8 7b cc 3b d7 40 0a 9f fd 29 09 4f 01 84 63 95 74 f3 9a e5 a1 31 52 17 bc d7
            89 49 91 44 72 13 bb 22 6c 25 b5 4d a8 63 70 fb cd 98 43 80 37 46 66 bb 8f fc b5 bf 40 c2 54 b0
            67 d2 7c 51 ce 4a d5 fe d8 29 c9 0b 50 5a 57 1b 7f 4d 1c ad 6a 52 3c da 77 0e 67 bc ea af 7e 89
            """))
        var scratch = [UInt32](repeating: 0, count: 32)
        state.withUnsafeMutableBufferPointer { s in scratch.withUnsafeMutableBufferPointer { Scrypt.blockMix(s.baseAddress!, scratch: $0.baseAddress!, r: 1) } }
        XCTAssertEqual(bytes(words: state), bytes("""
            a4 1f 85 9c 66 08 cc 99 3b 81 ca cb 02 0c ef 05 04 4b 21 81 a2 fd 33 7d fd 7b 1c 63 96 68 2f 29
            b4 39 31 68 e3 c9 e6 bc fe 6b c5 b7 a0 6d 96 ba e4 24 cc 10 2c 91 74 5c 24 ad 67 3d c7 61 8f 81
            20 ed c9 75 32 38 81 a8 05 40 f6 4c 16 2d cd 3c 21 07 7c fe 5f 8d 5f e2 b1 a4 16 8f 95 36 78 b7
            7d 3b 3d 80 3b 60 e4 ab 92 09 96 e5 9b 4d 53 b6 5d 2a 22 58 77 d5 ed f5 84 2c b9 f1 4e ef e4 25
            """))
    }

    func testROMixMatchesRFC7914() {
        var block = bytes("""
            f7 ce 0b 65 3d 2d 72 a4 10 8c f5 ab e9 12 ff dd 77 76 16 db bb 27 a7 0e 82 04 f3 ae 2d 0f 6f ad
            89 f6 8f 48 11 d1 e8 7b cc 3b d7 40 0a 9f fd 29 09 4f 01 84 63 95 74 f3 9a e5 a1 31 52 17 bc d7
            89 49 91 44 72 13 bb 22 6c 25 b5 4d a8 63 70 fb cd 98 43 80 37 46 66 bb 8f fc b5 bf 40 c2 54 b0
            67 d2 7c 51 ce 4a d5 fe d8 29 c9 0b 50 5a 57 1b 7f 4d 1c ad 6a 52 3c da 77 0e 67 bc ea af 7e 89
            """)
        Scrypt.roMix(&block, r: 1, n: 16)
        XCTAssertEqual(block, bytes("""
            79 cc c1 93 62 9d eb ca 04 7f 0b 70 60 4b f6 b6 2c e3 dd 4a 96 26 e3 55 fa fc 61 98 e6 ea 2b 46
            d5 84 13 67 3b 99 b0 29 d6 65 c3 57 60 1f b4 26 a0 b2 f4 bb a2 00 ee 9f 0a 43 d1 9b 57 1a 9c 71
            ef 11 42 e6 5d 5a 26 6f dd ca 83 2c e5 9f aa 7c ac 0b 9c f1 be 2b ff ca 30 0d 01 ee 38 76 19 c4
            ae 12 fd 44 38 f2 03 a0 e4 e1 c4 7e c3 14 86 1f 4e 90 87 cb 33 39 6a 68 73 e8 f9 d2 53 9a 4b 8e
            """))
    }

    func testPBKDF2MatchesRFC7914() throws {
        XCTAssertEqual(try Scrypt.pbkdf2SHA256(password: Array("passwd".utf8), salt: Array("salt".utf8), iterations: 1, length: 64), bytes("""
            55 ac 04 6e 56 e3 08 9f ec 16 91 c2 25 44 b6 05 f9 41 85 21 6d de 04 65 e6 8b 9d 57 c2 0d ac bc
            49 ca 9c cc f1 79 b6 45 99 16 64 b3 9d 77 ef 31 7c 71 b8 45 b1 e3 0b d5 09 11 20 41 d3 a1 97 83
            """))
    }

    func testScryptMatchesRFC7914() throws {
        XCTAssertEqual(try Scrypt.derive(password: [], salt: [], n: 16, r: 1, p: 1, length: 64), bytes("""
            77 d6 57 62 38 65 7b 20 3b 19 ca 42 c1 8a 04 97 f1 6b 48 44 e3 07 4a e8 df df fa 3f ed e2 14 42
            fc d0 06 9d ed 09 48 f8 32 6a 75 3a 0f c8 1f 17 e8 d3 e0 fb 2e 0d 36 28 cf 35 e2 0c 38 d1 89 06
            """), "Contraseña y sal vacías")
        XCTAssertEqual(try Scrypt.derive(password: Array("password".utf8), salt: Array("NaCl".utf8), n: 1024, r: 8, p: 16, length: 64), bytes("""
            fd ba be 1c 9d 34 72 00 78 56 e7 19 0d 01 e9 fe 7c 6a d7 cb c8 23 78 30 e7 73 76 63 4b 37 31 62
            2e af 30 d9 2e 22 a3 88 6f f1 09 27 9d 98 30 da c7 27 af b9 4a 83 ee 6d 83 60 cb df a2 cc 06 40
            """), "Paralelismo 16: cada bloque se mezcla por separado")
        XCTAssertEqual(try Scrypt.derive(password: Array("pleaseletmein".utf8), salt: Array("SodiumChloride".utf8), n: 16384, r: 8, p: 1, length: 64), bytes("""
            70 23 bd cb 3a fd 73 48 46 1c 06 cd 81 fd 38 eb fd a8 fb ba 90 4f 8e 3e a9 b5 43 f6 54 5d a1 f2
            d5 43 29 55 61 3f 0f cf 62 d4 97 05 24 2a 9a f9 e6 1e 85 dc 0d 65 1e 40 df cf 01 7b 45 57 58 87
            """), "Los parámetros de Cryptomator, con N a la mitad")
    }

    func testScryptRefusesParametersAHostileFileCouldUseAgainstTheMac() {
        XCTAssertThrowsError(try Scrypt.derive(password: [1], salt: [1], n: 1000, r: 8, p: 1, length: 32), "N tiene que ser potencia de dos")
        XCTAssertThrowsError(try Scrypt.derive(password: [1], salt: [1], n: 1 << 30, r: 8, p: 1, length: 32), "Pediría 128 GiB")
        XCTAssertThrowsError(try Scrypt.derive(password: [1], salt: [1], n: 16, r: 0, p: 1, length: 32))
    }

    // MARK: - Key wrap (RFC 3394)

    func testKeyWrapMatchesRFC3394() throws {
        let kek128 = bytes("000102030405060708090A0B0C0D0E0F"), kek256 = bytes("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
        let data128 = bytes("00112233445566778899AABBCCDDEEFF"), data256 = bytes("00112233445566778899AABBCCDDEEFF000102030405060708090A0B0C0D0E0F")
        XCTAssertEqual(try AESModes.wrap(data128, kek: kek128), bytes("1FA68B0A8112B447 AEF34BD8FB5A7B82 9D3E862371D2CFE5"), "§4.1")
        XCTAssertEqual(try AESModes.wrap(data128, kek: kek256), bytes("64E8C3F9CE0F5BA2 63E9777905818A2A 93C8191E7D6E8AE7"), "§4.3")
        let wrapped = try AESModes.wrap(data256, kek: kek256)
        XCTAssertEqual(wrapped, bytes("28C9F404C4B810F4 CBCCB35CFB87F826 3F5786E2D80ED326 CBC7F0E71A99F43B FB988B9B7A02DD21"), "§4.6")
        XCTAssertEqual(try AESModes.unwrap(wrapped, kek: kek256), data256)
        var wrongKEK = kek256; wrongKEK[0] ^= 1
        XCTAssertThrowsError(try AESModes.unwrap(wrapped, kek: wrongKEK)) { XCTAssertEqual($0 as? AESModes.Failure, .unauthentic) }
    }

    // MARK: - CMAC and SIV (RFC 4493, RFC 5297)

    func testCMACMatchesRFC4493() throws {
        let key = bytes("2b7e151628aed2a6abf7158809cf4f3c")
        XCTAssertEqual(try AESModes.cmac([], key: key), bytes("bb1d6929e95937287fa37d129b756746"))
        XCTAssertEqual(try AESModes.cmac(bytes("6bc1bee22e409f96e93d7e117393172a"), key: key), bytes("070a16b46b4d4144f79bdd9dd04a287c"))
        XCTAssertEqual(try AESModes.cmac(bytes("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411"), key: key),
                       bytes("dfa66747de9ae63030ca32611497c827"))
    }

    func testSIVMatchesRFC5297DeterministicExample() throws {
        // K1 (S2V) is the first half of the RFC's key, K2 (CTR) the second.
        let macKey = bytes("fffefdfc fbfaf9f8 f7f6f5f4 f3f2f1f0"), ctrKey = bytes("f0f1f2f3 f4f5f6f7 f8f9fafb fcfdfeff")
        let ad = bytes("10111213 14151617 18191a1b 1c1d1e1f 20212223 24252627"), plaintext = bytes("11223344 55667788 99aabbcc ddee")
        let output = try AESModes.sivEncrypt(plaintext, ctrKey: ctrKey, macKey: macKey, associatedData: [ad])
        XCTAssertEqual(output, bytes("85632d07 c6e8f37f 950acd32 0a2ecc93 40c02b96 90c4dc04 daef7f6a fe5c"))
        XCTAssertEqual(try AESModes.sivDecrypt(output, ctrKey: ctrKey, macKey: macKey, associatedData: [ad]), plaintext)
        var tampered = output; tampered[20] ^= 1
        XCTAssertThrowsError(try AESModes.sivDecrypt(tampered, ctrKey: ctrKey, macKey: macKey, associatedData: [ad]))
        XCTAssertThrowsError(try AESModes.sivDecrypt(output, ctrKey: ctrKey, macKey: macKey, associatedData: [bytes("00")]), "Otros datos asociados no abren")
    }

    func testSIVMatchesRFC5297NonceBasedExample() throws {
        let macKey = bytes("7f7e7d7c 7b7a7978 77767574 73727170"), ctrKey = bytes("40414243 44454647 48494a4b 4c4d4e4f")
        let ad1 = bytes("00112233 44556677 8899aabb ccddeeff deaddada deaddada ffeeddcc bbaa9988 77665544 33221100")
        let ad2 = bytes("10203040 50607080 90a0"), nonce = bytes("09f91102 9d74e35b d84156c5 635688c0")
        let plaintext = bytes("74686973 20697320 736f6d65 20706c61 696e7465 78742074 6f20656e 63727970 74207573 696e6720 5349562d 414553")
        XCTAssertEqual(try AESModes.sivEncrypt(plaintext, ctrKey: ctrKey, macKey: macKey, associatedData: [ad1, ad2, nonce]), bytes("""
            7bdb6e3b 432667eb 06f4d14b ff2fbd0f cb900f2f ddbe4043 26601965 c889bf17
            dba77ceb 094fa663 b7a3f748 ba8af829 ea64ad54 4a272e9c 485b62a3 fd5c0d
            """))
    }

    func testEncodings() {
        XCTAssertEqual(CryptomatorEncoding.base32(Array("foobar".utf8)), "MZXW6YTBOI======", "RFC 4648 §10")
        XCTAssertEqual(CryptomatorEncoding.base32(Array("f".utf8)), "MY======")
        XCTAssertEqual(CryptomatorEncoding.base64url([0xFB, 0xFF]), "-_8=", "Alfabeto URL y relleno, como Cryptomator")
        XCTAssertEqual(CryptomatorEncoding.base64urlDecode("-_8="), [0xFB, 0xFF])
        XCTAssertEqual(CryptomatorEncoding.base64urlDecode("-_8"), [0xFB, 0xFF], "Sin relleno también se lee")
        XCTAssertNil(CryptomatorEncoding.base64urlDecode("+/8="), "El alfabeto normal no es un nombre de Cryptomator")
    }

    // MARK: - Cryptomator's own vectors

    /// masterkey.cryptomator from cryptolib-swift's MasterkeyFileTests: passphrase "asd", scrypt N = 2, both keys zero.
    private let publishedMasterkeyFile = Data("""
        {
            "version": 7,
            "scryptSalt": "AAAAAAAAAAA=",
            "scryptCostParam": 2,
            "scryptBlockSize": 8,
            "primaryMasterKey": "mM+qoQ+o0qvPTiDAZYt+flaC3WbpNAx1sTXaUzxwpy0M9Ctj6Tih/Q==",
            "hmacMasterKey": "mM+qoQ+o0qvPTiDAZYt+flaC3WbpNAx1sTXaUzxwpy0M9Ctj6Tih/Q==",
            "versionMac": "cn2sAK6l9p1/w9deJVUuW3h7br056mpv5srvALiYw+g="
        }
        """.utf8)

    func testPublishedMasterkeyFileUnlocks() throws {
        let file = try CryptomatorMasterkeyFile.decode(publishedMasterkeyFile)
        XCTAssertEqual(try file.deriveKEK(passphrase: "asd"), bytes("8CF4A04EC845F428 B2F9F9E1D9DF08D2 6211D9AFE2F55FDE DFCBB5E75AEF34F9"))
        let key = try file.unlock(passphrase: "asd")
        XCTAssertEqual(key.encryptionKey, [UInt8](repeating: 0, count: 32))
        XCTAssertEqual(key.macKey, [UInt8](repeating: 0, count: 32))
    }

    func testWrongPassphraseAndTamperedVersionAreRefused() throws {
        let file = try CryptomatorMasterkeyFile.decode(publishedMasterkeyFile)
        XCTAssertThrowsError(try file.unlock(passphrase: "qwe")) { XCTAssertEqual($0 as? CryptomatorError, .invalidPassphrase) }
        var tampered = file; tampered.versionMac = "cn2sAK6l9p1/w9deJVUuW3h7br056mpv5srvALiYw+G="
        XCTAssertThrowsError(try tampered.unlock(passphrase: "asd")) { error in
            guard case .malformed = error as? CryptomatorError else { return XCTFail("\(error)") }
        }
        var downgraded = file; downgraded.version = 6
        XCTAssertThrowsError(try downgraded.unlock(passphrase: "asd"), "Cambiar la versión sin la clave se nota")
    }

    func testLockingReproducesThePublishedMasterkeyFile() throws {
        // cryptolib-swift's testLock: keys 0x55 and 0x77, salt of 0xF0, passphrase "asd", N = 2, version 7.
        let key = CryptomatorMasterkey(encryptionKey: [UInt8](repeating: 0x55, count: 32), macKey: [UInt8](repeating: 0x77, count: 32))
        let file = try CryptomatorMasterkeyFile.lock(key, passphrase: "asd", version: 7, costParam: 2, salt: [UInt8](repeating: 0xF0, count: 8))
        XCTAssertEqual(file.scryptSalt, "8PDw8PDw8PA=")
        XCTAssertEqual(file.scryptBlockSize, 8)
        XCTAssertEqual(file.primaryMasterKey, "jvdghkTc01VISrFly37pgaT/UKtXrDCvZcU3tT9Y98zyzn/pJ91bxw==")
        XCTAssertEqual(file.hmacMasterKey, "99I+J4bT3rVpZE8yZwKRV9gHVRmQ8XQEujAL9IuwLTc2D3mg5JEjKA==")
        XCTAssertEqual(file.versionMac, "sAWFgFNhmtMPeNWr4zh+9Ps7GOtT0pknX11PRQ7eC9Q=")
        let reread = try CryptomatorMasterkeyFile.decode(file.encoded())
        XCTAssertEqual(try reread.unlock(passphrase: "asd"), key)
        XCTAssertFalse(String(decoding: try file.encoded(), as: UTF8.self).contains("\\/"), "Sin barras escapadas en el JSON")
    }

    func testNormalizedPassphrasesDeriveTheSameKey() throws {
        let key = try CryptomatorMasterkey.random()
        let file = try CryptomatorMasterkeyFile.lock(key, passphrase: "caf\u{00E9}", costParam: 2)
        XCTAssertEqual(try file.unlock(passphrase: "cafe\u{0301}"), key, "La é compuesta y la descompuesta son la misma contraseña")
        XCTAssertEqual(file.version, 999, "El formato 8 escribe 999 en el campo heredado")
    }

    /// cryptofs's VaultConfigTest: a token signed with 64 bytes of 0x55.
    private let publishedToken = "eyJraWQiOiJURVNUX0tFWSIsInR5cCI6IkpXVCIsImFsZyI6IkhTMjU2In0.eyJmb3JtYXQiOjgsInNob3J0ZW5pbmdUaHJlc2hvbGQiOjIyMCwianRpIjoiZjRiMjlmM2EtNDdkNi00NjlmLTk2NGMtZjRjMmRhZWU4ZWI2IiwiY2lwaGVyQ29tYm8iOiJTSVZfQ1RSTUFDIn0.V7pqSXX1tBRgmntL1sXovnhNR4Z1_7z3Jzrq7NMqPO8"

    func testPublishedVaultConfigVerifies() throws {
        let config = try CryptomatorVaultConfig.verify(publishedToken, rawKey: [UInt8](repeating: 0x55, count: 64))
        XCTAssertEqual(config.format, 8)
        XCTAssertEqual(config.cipherCombo, .sivCTRMAC)
        XCTAssertEqual(config.shorteningThreshold, 220)
        XCTAssertEqual(config.keyID, "TEST_KEY")
        XCTAssertNil(config.masterkeyFileName, "Una clave que no viene de un archivo no se puede pedir con contraseña")
        XCTAssertEqual(try CryptomatorVaultConfig.unverifiedKeyID(publishedToken), "TEST_KEY")
        for position in [0, 1, 31, 32, 63] {
            var key = [UInt8](repeating: 0x55, count: 64); key[position] = 0x77
            XCTAssertThrowsError(try CryptomatorVaultConfig.verify(publishedToken, rawKey: key), "Byte \(position)")
        }
        let unsigned = "eyJraWQiOiJURVNUX0tFWSIsInR5cCI6IkpXVCIsImFsZyI6Im5vbmUifQ.eyJmb3JtYXQiOjgsInNob3J0ZW5pbmdUaHJlc2hvbGQiOjIyMCwianRpIjoiZjRiMjlmM2EtNDdkNi00NjlmLTk2NGMtZjRjMmRhZWU4ZWI2IiwiY2lwaGVyQ29tYm8iOiJTSVZfQ1RSTUFDIn0."
        XCTAssertThrowsError(try CryptomatorVaultConfig.verify(unsigned, rawKey: [UInt8](repeating: 0x55, count: 64)), "alg none no se acepta")
    }

    func testOwnVaultConfigRoundTrips() throws {
        let key = try CryptomatorMasterkey.random()
        let config = CryptomatorVaultConfig.new()
        let token = try config.token(rawKey: key.raw)
        XCTAssertFalse(token.contains("="), "Un JWT va sin relleno")
        XCTAssertEqual(try CryptomatorVaultConfig.verify(token, rawKey: key.raw), config)
        XCTAssertEqual(config.masterkeyFileName, "masterkey.cryptomator")
        let header = try XCTUnwrap(CryptomatorEncoding.base64urlDecode(String(token.split(separator: ".")[0])))
        XCTAssertEqual(String(decoding: header, as: UTF8.self), #"{"kid":"masterkeyfile:masterkey.cryptomator","typ":"JWT","alg":"HS256"}"#)
    }

    private var publishedKey: CryptomatorMasterkey {
        CryptomatorMasterkey(encryptionKey: [UInt8](repeating: 0x55, count: 32), macKey: [UInt8](repeating: 0x77, count: 32))
    }

    func testDirectoryHashesMatchCryptolib() throws {
        let cryptor = CryptomatorCryptor(masterkey: publishedKey)
        XCTAssertEqual(try cryptor.hashDirectoryID(""), "VLWEHT553J5DR7OZLRJAYDIWFCXZABOD", "La raíz")
        XCTAssertEqual(try cryptor.hashDirectoryID("918acfbd-a467-3f77-93f1-f4a44f9cfe9c"), "7C3USOO3VU7IVQRKFMRFV3QE4VEZJECV")
        let path = try cryptor.directoryPath("")
        XCTAssertEqual(path.shard, "VL"); XCTAssertEqual(path.name, "WEHT553J5DR7OZLRJAYDIWFCXZABOD")
    }

    func testNamesAreBoundToTheirDirectory() throws {
        let cryptor = CryptomatorCryptor(masterkey: publishedKey)
        let encrypted = try cryptor.encryptName("hello.txt", parentDirID: "foo")
        XCTAssertEqual(try cryptor.encryptName("hello.txt", parentDirID: "foo"), encrypted, "Determinista")
        XCTAssertEqual(try cryptor.decryptName(encrypted, parentDirID: "foo"), "hello.txt")
        XCTAssertThrowsError(try cryptor.decryptName(encrypted, parentDirID: "bar"), "Un archivo movido sin volver a cifrar su nombre no se abre")
        XCTAssertThrowsError(try cryptor.decryptName("****", parentDirID: "foo"))
        XCTAssertThrowsError(try cryptor.decryptName("test", parentDirID: "foo"))
        XCTAssertEqual(try cryptor.encryptName("cafe\u{0301}", parentDirID: ""), try cryptor.encryptName("caf\u{00E9}", parentDirID: ""), "NFC antes de cifrar")
        // Shortening: base64url(sha1(full .c9r name)) + .c9s, past 220 characters.
        let long = String(repeating: "nombre largo ", count: 20)
        let node = try cryptor.nodeName(long, parentDirID: "", threshold: 220)
        XCTAssertTrue(node.full.hasSuffix(".c9r")); XCTAssertGreaterThan(node.full.count, 220)
        XCTAssertEqual(node.node, CryptomatorEncoding.base64url(Array(Insecure.SHA1.hash(data: Array(node.full.utf8)))) + ".c9s")
        XCTAssertEqual(node.node.count, 32)
        let short = try cryptor.nodeName("a.txt", parentDirID: "", threshold: 220)
        XCTAssertEqual(short.node, short.full)
    }

    func testGCMHeaderMatchesCryptolib() throws {
        var cryptor = CryptomatorCryptor(masterkey: publishedKey)
        cryptor.random = { [UInt8](repeating: 0xF0, count: $0) }
        let header = try cryptor.newHeader()
        let expected = bytes("""
            F0F0F0F0F0F0F0F0F0F0F0F0
            1C8719F03122868FDB9D9703A08608D5885896C2E6604BB9EA6431D4A05D476FE41F3231F2C0611F
            6D42988243F21F43F644FD6DF7A93F0B
            """)
        XCTAssertEqual(try cryptor.encryptHeader(header), expected)
        XCTAssertEqual(expected.count, 68, "Cabecera de 68 bytes")
        XCTAssertEqual(try cryptor.decryptHeader(expected), CryptomatorCryptor.Header(nonce: [UInt8](repeating: 0xF0, count: 12), contentKey: [UInt8](repeating: 0xF0, count: 32)))
        var tampered = expected; tampered[30] ^= 1
        XCTAssertThrowsError(try cryptor.decryptHeader(tampered))
    }

    func testGCMChunkMatchesCryptolib() throws {
        let cryptor = CryptomatorCryptor(masterkey: publishedKey)
        let header = CryptomatorCryptor.Header(nonce: [UInt8](repeating: 0x55, count: 12), contentKey: [UInt8](repeating: 0x77, count: 32))
        let chunk = bytes("555555555555555555555555 52C5EE8D7FB44EF28AEC55 3CC70265E5352CB5A09A43AE0F5CA15D")
        XCTAssertEqual(try cryptor.decryptChunk(chunk, number: 0, header: header), Array("hello world".utf8))
        XCTAssertThrowsError(try cryptor.decryptChunk(chunk, number: 1, header: header), "Un trozo en otra posición no abre")
        XCTAssertEqual(try cryptor.encryptChunk(Array("hello world".utf8), number: 0, header: header, nonce: [UInt8](repeating: 0x55, count: 12)), chunk)
    }

    func testCTRMACHeaderMatchesCryptolib() throws {
        var cryptor = CryptomatorCryptor(masterkey: publishedKey, combo: .sivCTRMAC)
        cryptor.random = { [UInt8](repeating: 0xF0, count: $0) }
        let expected = bytes("""
            F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0F0
            0D91F29CC635D75E1E42231EC79057E38D98F358072C9F03BCEA5A983B6862893EBC5E5E2739CB8E
            D42761068E7F3A4EC79F4D3E2057DCE465A5FF93C27BD2B83FE3D08CB392ED96
            """)
        XCTAssertEqual(try cryptor.encryptHeader(cryptor.newHeader()), expected)
        XCTAssertEqual(cryptor.headerSize, 88)
        XCTAssertEqual(try cryptor.decryptHeader(expected).contentKey, [UInt8](repeating: 0xF0, count: 32))
        let header = try cryptor.newHeader()
        let chunk = try cryptor.encryptChunk(Array("hola".utf8), number: 3, header: header)
        XCTAssertEqual(try cryptor.decryptChunk(chunk, number: 3, header: header), Array("hola".utf8))
        XCTAssertThrowsError(try cryptor.decryptChunk(chunk, number: 2, header: header))
    }

    func testSizesMatchCryptolib() {
        let cryptor = CryptomatorCryptor(masterkey: publishedKey)
        let header = Int64(cryptor.headerSize), overhead = Int64(28), chunk = Int64(32 * 1024)
        let pairs: [(Int64, Int64)] = [(0, 0), (1, 1 + overhead), (chunk - 1, chunk - 1 + overhead), (chunk, chunk + overhead),
                                       (chunk + 1, chunk + 1 + 2 * overhead), (2 * chunk, 2 * chunk + 2 * overhead), (2 * chunk + 1, 2 * chunk + 1 + 3 * overhead)]
        for (clear, cipher) in pairs {
            XCTAssertEqual(cryptor.ciphertextSize(cleartext: clear), cipher + header, "\(clear)")
            XCTAssertEqual(cryptor.cleartextSize(ciphertext: cipher + header), clear, "\(cipher)")
        }
        XCTAssertNil(cryptor.cleartextSize(ciphertext: header + 1), "Un trozo más corto que su envoltorio no existe")
        XCTAssertNil(cryptor.cleartextSize(ciphertext: header - 1))
        XCTAssertNil(cryptor.cleartextSize(ciphertext: header + chunk + overhead + 1))
        XCTAssertEqual(cryptor.cleartextSize(ciphertext: header + overhead), 0, "El trozo vacío final que deja Cryptomator")
    }

    func testFileContentsRoundTripInChunksAndDetectTampering() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cryptomator-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cryptor = CryptomatorCryptor(masterkey: try .random())
        for size in [0, 1, 32 * 1024, 32 * 1024 + 1, 100_000] {
            let clear = directory.appendingPathComponent("claro-\(size)"), cipher = directory.appendingPathComponent("cifrado-\(size)"),
                back = directory.appendingPathComponent("vuelta-\(size)")
            let data = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            try data.write(to: clear)
            try cryptor.encryptFile(from: clear, to: cipher)
            let cipherSize = Int64(try Data(contentsOf: cipher).count)
            XCTAssertEqual(cipherSize, cryptor.ciphertextSize(cleartext: Int64(size)))
            XCTAssertEqual(cryptor.cleartextSize(ciphertext: cipherSize), Int64(size))
            try cryptor.decryptFile(from: cipher, to: back)
            XCTAssertEqual(try Data(contentsOf: back), data, "\(size) bytes")
            XCTAssertEqual(try cryptor.decrypt([UInt8](try Data(contentsOf: cipher))), [UInt8](data))
        }
        // One flipped bit in the second chunk: nothing is left behind.
        let cipher = directory.appendingPathComponent("cifrado-100000"), back = directory.appendingPathComponent("dañado")
        var bytes = try Data(contentsOf: cipher)
        bytes[cryptor.headerSize + cryptor.ciphertextChunkSize + 40] ^= 0x01
        try bytes.write(to: cipher)
        XCTAssertThrowsError(try cryptor.decryptFile(from: cipher, to: back))
        XCTAssertFalse(FileManager.default.fileExists(atPath: back.path), "Un descifrado a medias no se queda en disco")
        // Two chunks swapped: the chunk number in the AAD catches it.
        let original = try Data(contentsOf: directory.appendingPathComponent("cifrado-32769"))
        XCTAssertThrowsError(try cryptor.decrypt([UInt8](original.prefix(cryptor.headerSize) + original.suffix(29) + original.dropFirst(cryptor.headerSize).prefix(cryptor.ciphertextChunkSize))))
    }
}
