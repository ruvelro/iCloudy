import XCTest
@testable import iCloudy

/// The published vectors that `CryptomatorCryptoTests` and `SSHKeyTests` did not already cover, for the cryptography
/// iCloudy writes itself (SECURITY.md lists it): the rest of RFC 3394's key wrap examples, the last RFC 4493 CMAC
/// example, and OpenBSD's regression vectors for bcrypt_pbkdf, NUL bytes, odd lengths and round counts included.
final class CryptoVectorsTests: XCTestCase {
    private func bytes(_ hex: String) -> [UInt8] {
        let clean = Array(hex.filter(\.isHexDigit))
        return stride(from: 0, to: clean.count, by: 2).map { UInt8(String(clean[$0...$0 + 1]), radix: 16)! }
    }

    // MARK: - RFC 3394 §4.2, §4.4, §4.5

    func testKeyWrapMatchesTheRemainingRFC3394Examples() throws {
        let kek192 = bytes("000102030405060708090A0B0C0D0E0F1011121314151617")
        let kek256 = bytes("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F")
        let data128 = bytes("00112233445566778899AABBCCDDEEFF"), data192 = bytes("00112233445566778899AABBCCDDEEFF0001020304050607")
        let cases: [(kek: [UInt8], data: [UInt8], wrapped: String, section: String)] = [
            (kek192, data128, "96778B25AE6CA435 F92B5B97C050AED2 468AB8A17AD84E5D", "§4.2"),
            (kek192, data192, "031D33264E15D332 68F24EC260743EDC E1C6C7DDEE725A93 6BA814915C6762D2", "§4.4"),
            (kek256, data192, "A8F9BC1612C68B3F F6E6F4FBE30E71E4 769C8B80A32CB895 8CD5D17D6B254DA1", "§4.5"),
        ]
        for example in cases {
            let wrapped = try AESModes.wrap(example.data, kek: example.kek)
            XCTAssertEqual(wrapped, bytes(example.wrapped), example.section)
            XCTAssertEqual(try AESModes.unwrap(wrapped, kek: example.kek), example.data, example.section)
        }
    }

    // MARK: - RFC 4493 §4, example 4

    func testCMACOfAFourBlockMessageMatchesRFC4493() throws {
        let message = bytes("""
            6bc1bee2 2e409f96 e93d7e11 7393172a ae2d8a57 1e03ac9c 9eb76fac 45af8e51
            30c81c46 a35ce411 e5fbc119 1a0a52ef f69f2445 df4f9b17 ad2b417b e66c3710
            """)
        XCTAssertEqual(try AESModes.cmac(message, key: bytes("2b7e151628aed2a6abf7158809cf4f3c")), bytes("51f0bebf 7e3b9d92 fc497417 79363cfe"))
    }

    // MARK: - bcrypt_pbkdf (OpenBSD regress/lib/libutil/bcrypt_pbkdf)

    func testBCryptPBKDFMatchesOpenBSDsRegressionVectors() throws {
        let lorem = "Lorem ipsum dolor sit amet, consectetur adipisicing elit, sed do eiusmod tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse cillum dolore eu fugiat nulla pariatur. Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia deserunt mollit anim id est laborum."
        let cases: [(password: String, salt: String, rounds: Int, key: String)] = [
            ("password", "\0", 4, "c12b566235eee04c212598970a579a67"),
            ("\0", "salt", 4, "6051be18c2f4f82cbf0efee5471b4bb9"),
            ("password\0", "salt\0", 4, "7410e44cf4fa07bfaac8a928b1727fac001375e7bf7384370f48efd121743050"),
            ("pass\0wor", "sa\0l", 4, "c2bffd9db38f6569efef4372f4de83c0"),
            ("pass\0word", "sa\0lt", 4, "4ba4ac3925c0e8d7f0cdb6bb1684a56f"),
            ("password", "salt", 8, "e1367ec5151a33faac4cc1c144cd23fa15d5548493ecc99b9b5d9c0d3b27bec76227ea66088b849b20ab7aa478010246e74bba51723fefa9f9474d6508845e8d"),
            ("password", "salt", 42, "833cf0dcf56db65608e8f0dc0ce882bd"),
            (lorem, "salis\0", 8, "10978b07253df57f71a162eb0e8ad30a"),
        ]
        for example in cases {
            let expected = bytes(example.key)
            let key = try BCryptPBKDF.derive(password: Data(example.password.utf8), salt: Data(example.salt.utf8), length: expected.count, rounds: example.rounds)
            XCTAssertEqual(Array(key), expected, "\(example.password.prefix(12).debugDescription) / \(example.salt.debugDescription) / \(example.rounds)")
        }
    }
}
