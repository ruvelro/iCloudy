import XCTest
import CryptoKit
@testable import iCloudy

/// Mega is end-to-end encrypted, so these primitives are not an implementation detail: if any of them is wrong the
/// user sees unreadable names or corrupted downloads rather than an error. The expected values come from OpenSSL and
/// from the AES specification, never from iCloudy itself, so the tests can fail the code instead of agreeing with it.
final class MegaCryptoTests: XCTestCase {
    private func bytes(_ hex: String) -> Data {
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            result.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return result
    }
    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private let key = Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15])

    func testBase64IsURLSafeAndUnpadded() {
        let data = Data([0xFB, 0xFF, 0xBE, 0x01])
        let text = MegaCrypto.encode(data)
        XCTAssertFalse(text.contains("+") || text.contains("/") || text.contains("="), text)
        XCTAssertEqual(MegaCrypto.decode(text), data)
        XCTAssertEqual(MegaCrypto.decode(MegaCrypto.encode(Data([1]))), Data([1]), "Un solo byte también vuelve entero")
        XCTAssertEqual(MegaCrypto.decode("no es base64 válido!!"), Data(), "Un valor corrupto no revienta, devuelve vacío")
    }

    func testMultiPrecisionIntegersAreReadInSequence() {
        // Two numbers: eight bits holding 0x2A, then sixteen bits holding 0x0102.
        let encoded = Data([0, 8, 0x2A]) + Data([0, 16, 0x01, 0x02])
        let numbers = MegaCrypto.integers(encoded, count: 4)
        XCTAssertEqual(numbers.count, 2, "Se leen los que hay, sin inventar los que faltan")
        XCTAssertEqual(numbers[0].data, Data([0x2A]))
        XCTAssertEqual(numbers[1].data, Data([0x01, 0x02]))
        XCTAssertEqual(MegaCrypto.integers(Data([0, 64, 1]), count: 1).count, 0, "Un tamaño que no cabe se descarta")
    }

    func testAESMatchesTheSpecificationAndOpenSSL() throws {
        let plain = bytes("00112233445566778899aabbccddeeff")
        // FIPS-197, appendix C.1.
        let cipher = try MegaCrypto.ecb(plain, key: key, encrypt: true)
        XCTAssertEqual(hex(cipher), "69c4e0d86a7b0430d8cdb78070b4c55a")
        XCTAssertEqual(try MegaCrypto.ecb(cipher, key: key), plain, "Descifrar deshace exactamente el cifrado")

        XCTAssertEqual(hex(try MegaCrypto.cbc(plain, key: key, encrypt: true)), "69c4e0d86a7b0430d8cdb78070b4c55a",
                       "Con vector inicial de ceros y un solo bloque, CBC coincide con ECB")

        let keystream = try MegaCrypto.ctr(Data(count: 48), key: key, nonce: bytes("0123456789abcdef"), blockOffset: 2)
        XCTAssertEqual(hex(keystream), "6c3412d9f9aef9daedcd082f5043d756e988b68ebe6ae6288b33119c05448776b72cbae8e6e84eb5e7dab6d60f6b6b82")
    }

    func testCounterModeStartsWhereTheChunkStarts() throws {
        // Every chunk is decrypted on its own, so block 2 of a long stream must equal block 0 of a stream started there.
        let long = try MegaCrypto.ctr(Data(count: 64), key: key, nonce: bytes("0123456789abcdef"), blockOffset: 0)
        let jumped = try MegaCrypto.ctr(Data(count: 32), key: key, nonce: bytes("0123456789abcdef"), blockOffset: 2)
        XCTAssertEqual(jumped, long.suffix(32))
    }

    func testPasswordDerivationMatchesOpenSSL() throws {
        let derived = try MegaCrypto.derive(password: "contraseña", salt: bytes("0011223344556677"))
        XCTAssertEqual(hex(derived.key), "85feeef13fd23596d22cc83bd595bcf9")
        XCTAssertEqual(derived.hash, MegaCrypto.encode(bytes("13c3f64c53cd62917dd19443a16d85ef")),
                       "La segunda mitad es la prueba que se envía al servidor, no la clave")
    }

    func testTheLegacyDerivationIsStableAndSeparateFromTheModernOne() throws {
        // Pre-2018 accounts. There is no published vector to compare against, so what is checked is that the function
        // is deterministic, sized right, and sensitive to the password: a constant result would pass sign-in never.
        let first = try MegaCrypto.legacyKey(password: "contraseña")
        XCTAssertEqual(first.count, 16)
        XCTAssertEqual(first, try MegaCrypto.legacyKey(password: "contraseña"))
        XCTAssertNotEqual(first, try MegaCrypto.legacyKey(password: "contraseñas"))
        let hash = try MegaCrypto.legacyHash("ana@ejemplo.com", key: first)
        XCTAssertEqual(MegaCrypto.decode(hash).count, 8)
        XCTAssertNotEqual(hash, try MegaCrypto.legacyHash("otra@ejemplo.com", key: first))
    }

    /// The token of a real challenge Mega issued, kept so the layout cannot drift.
    private let challengeToken = "mH7V46ouyOeSYe2ni_kuk9Ec9wgmW3PxVUu-p8TX6aCgBK05XddtJ-ioehg5FB8W"

    func testTheProofOfWorkThresholdMatchesMegaFormula() {
        // The easiness byte packs two numbers: the low six bits scale the threshold, the top two shift it.
        XCTAssertEqual(MegaCrypto.threshold(easiness: 192), 16_777_216, "La dificultad que Mega usa hoy al iniciar sesión")
        XCTAssertEqual(MegaCrypto.threshold(easiness: 255), 2_130_706_432, "La más fácil posible")
        XCTAssertEqual(MegaCrypto.threshold(easiness: 0), 8, "La más difícil posible")
        XCTAssertGreaterThan(MegaCrypto.threshold(easiness: 255), MegaCrypto.threshold(easiness: 192),
                             "Más «easiness» significa menos trabajo")
    }

    func testTheProofOfWorkReproducesAKnownAnswer() throws {
        // Verified against Mega's own servers: solving a challenge this way turns their 402 into a 200.
        XCTAssertEqual(try MegaCrypto.hashcash(token: challengeToken, easiness: 255), "AQAAAA")
        XCTAssertEqual(try MegaCrypto.hashcash(token: challengeToken, easiness: 216), "AgAAAA")
    }

    func testTheProofOfWorkAnswerActuallyClearsTheThreshold() throws {
        // Independently of the stored answer, the prefix has to satisfy what the server will check.
        let easiness = 246
        let prefix = try MegaCrypto.hashcash(token: challengeToken, easiness: easiness)
        var buffer = MegaCrypto.decode(prefix)
        XCTAssertEqual(buffer.count, 4, "El prefijo son cuatro bytes")
        let seed = MegaCrypto.decode(challengeToken)
        for _ in 0..<262_144 { buffer.append(seed) }
        let digest = [UInt8](SHA256.hash(data: buffer))
        let head = UInt32(digest[0]) << 24 | UInt32(digest[1]) << 16 | UInt32(digest[2]) << 8 | UInt32(digest[3])
        XCTAssertLessThanOrEqual(head, MegaCrypto.threshold(easiness: easiness))
    }

    func testAMalformedChallengeIsRefusedInsteadOfHashedForever() async {
        for bad in ["", "1:192", "2:192:0:" + challengeToken, "1:999:0:" + challengeToken, "1:192:0:corto"] {
            do { _ = try await MegaAPI.solve(bad); XCTFail("Aceptó «\(bad)»") }
            catch { XCTAssertTrue(error.localizedDescription.contains("no se entiende"), error.localizedDescription) }
        }
        let good = try? await MegaAPI.solve("1:255:0:" + challengeToken)
        XCTAssertEqual(good, "1:\(challengeToken):AQAAAA", "La cabecera lleva la versión, el token y el prefijo")
    }

    func testAFileKeyUnpacksIntoItsThreeParts() throws {
        let packed = MegaCrypto.randomKey()
        let parts = try XCTUnwrap(MegaCrypto.unpack(fileKey: packed))
        XCTAssertEqual(parts.key.count, 16)
        XCTAssertEqual(parts.nonce.count, 8)
        XCTAssertEqual(parts.mac.count, 8)
        XCTAssertEqual(MegaCrypto.pack(key: parts.key, nonce: parts.nonce, mac: parts.mac), packed,
                       "Rehacer la clave devuelve exactamente los 32 bytes que Mega guarda")
        XCTAssertNil(MegaCrypto.unpack(fileKey: Data(count: 16)), "Una clave de carpeta no tiene partes de archivo")
    }

    func testNamesAreUnreadableWithTheWrongKeyInsteadOfWrong() throws {
        let encoded = try MegaCrypto.encodeAttributes(["n": "Informe anual.pdf"], key: key)
        XCTAssertEqual(encoded.count % 16, 0)
        XCTAssertEqual(MegaCrypto.attributes(encoded, key: key)?["n"] as? String, "Informe anual.pdf")
        XCTAssertNil(MegaCrypto.attributes(encoded, key: Data(count: 16)),
                     "Sin el prefijo MEGA no se acepta el resultado, que sería basura con aspecto de nombre")
        XCTAssertNil(MegaCrypto.attributes(Data(count: 8), key: key))
    }

    func testChunkBoundariesGrowAsMegaDefinesThem() {
        XCTAssertTrue(MegaCrypto.chunks(of: 0).isEmpty)
        XCTAssertEqual(MegaCrypto.chunks(of: 100).map(\.length), [100], "Un archivo pequeño es un solo trozo")
        let lengths = MegaCrypto.chunks(of: 6 * 1024 * 1024).map(\.length)
        XCTAssertEqual(lengths.prefix(8).map { $0 / 1024 }, [128, 256, 384, 512, 640, 768, 896, 1024])
        XCTAssertTrue(lengths.dropFirst(8).allSatisfy { $0 <= 1024 * 1024 }, "A partir del octavo son de 1 MiB")
        XCTAssertEqual(lengths.reduce(0, +), 6 * 1024 * 1024, "Los trozos cubren el archivo entero sin solaparse")
        let offsets = MegaCrypto.chunks(of: 6 * 1024 * 1024).map(\.offset)
        XCTAssertEqual(offsets.first, 0)
        XCTAssertTrue(offsets.allSatisfy { $0 % 16 == 0 }, "Cada trozo empieza en un bloque de AES")
    }

    func testTheContentMACMatchesOpenSSL() throws {
        // The chunk MAC is a CBC-MAC: the last block of a CBC encryption seeded with the nonce twice over.
        let mac = try MegaCrypto.chunkMAC(Data("Los ficheros de Mega viajan cifr".utf8), key: key, nonce: bytes("0123456789abcdef"))
        XCTAssertEqual(hex(mac), "c726d50bbd1723df05b7b104784e4a13")

        let folded = try MegaCrypto.metaMAC(chunks: [mac], key: key)
        XCTAssertEqual(folded.count, 8, "Es lo que cabe dentro de la clave del archivo")
        let changed = try MegaCrypto.chunkMAC(Data("Los ficheros de Mega viajan cifF".utf8), key: key, nonce: bytes("0123456789abcdef"))
        XCTAssertNotEqual(try MegaCrypto.metaMAC(chunks: [changed], key: key), folded,
                          "Un byte distinto en el contenido cambia la comprobación")
        XCTAssertNotEqual(try MegaCrypto.metaMAC(chunks: [mac, mac], key: key), folded, "El orden y el número de trozos cuentan")
    }
}
