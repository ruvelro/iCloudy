import XCTest
@testable import iCloudy

/// Mega proves a session belongs to the account by handing back a challenge encrypted with the account's public key.
/// Getting the arithmetic wrong means a sign-in that fails with no useful message, so the vectors below are checked
/// against a reference implementation rather than against iCloudy itself.
final class MegaBigIntTests: XCTestCase {
    private func number(_ hex: String) -> MegaBigInt {
        var hex = hex
        if hex.count % 2 == 1 { hex = "0" + hex }
        var bytes = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        return MegaBigInt(bytes)
    }
    private func hex(_ value: MegaBigInt) -> String { value.data.map { String(format: "%02x", $0) }.joined().drop { $0 == "0" }.description }

    private lazy var p = number("af62b247825c759c00dea912190a381ab40b1dcb22cbb01b78754aa0b9504fc6aacef67daf993b59d7b32ef0b0e6cb87" +
        "17bdf5f4e4a9a4991b82a0d899ba64d5146968f417ba0f41fe2888418b95077b458cc9dcb3bf370f6de6f96ce6d51487" +
        "30c88506f65c201adde8422c8a0d50bc739c02fa7d81c54ce75035dbaa75bd45")
    private lazy var q = number("c63ca27193546f8cddab6d5e42f7ef1de49aa44b20d2e46035d1f29a5de784dc9579077f932f04a568837c4c4b9f8a70" +
        "651638ebe88f2169a2e6e88ccc7822cbf4df4f94e7c54eabe234ecd3db55cc8cd0ad07f9689d9ed7e3a2975ba280259d" +
        "c86ce538f61a46b124b0dfe3ce270c5e717cffa0e3aaa70dc0d2eae7f0347323")
    private lazy var d = number("4fe3b11f9f7922bf7df60a5e0c275502cb2447b127d97645e670b83cc9fcba3ab8d0043e832fcbc530cba8e6e7f3c8c4" +
        "af4fc3618d956ee53cafdee6fd0908742045363ce9eed808190744895f8a424a7b7b2b2eeb3c41399dba4ad8bc0570cf" +
        "786a69020f7bdc0cbcf25c9e4afba87b7e9fce390a6663fac3b79fa76dcce491420dcb7aeece1f6484c1359c7819ea2b" +
        "998f82e47283e24935735e24327f13d2a8043185a731f38edc89aaee5dc24f6b90dfb1490b865575d10f280b11f53931" +
        "45f6a77c6b70a0bbd0f2eeae8b0d76f8718046f806cf59da3e8822582cf8383a31933d89068dd9086d375372bb46dc83" +
        "4aff27cd07feb88a6ca50b544efbb241")
    private lazy var ciphertext = number("7817530286fab69f37d1d95bc8ee139971032205c640e7caa44be64a19af213dec49cd8ca34d7eb85f67d9fe4e470254" +
        "164a437f46692386b40aea5ff17fae744e5221b4d6fbe3487e613590e74dd532fefac83a4096485ad397f736f15e3f2a" +
        "dbf8873d61aa1de10a7a9f68ca2cd61f4616a4372307753618d2a52f7edfa7a2e9fc9cbb82f707eec3de8d4d6972efe0" +
        "adea4efe29535237d863f573d950372c3c1faa14713e4ef2f24ef2dd72c27298c8666d63b44adc1ca0349147106879bf" +
        "c1a2648672217d971a12a1b36659ab2c0c69d2bdc1ae4782d693169ac361faf390256299766ba5847add761485abbbe8" +
        "c3b9ab0b6d89dadee2e79403cec60be4")
    private lazy var plaintext = number("b628526a27380fbbeac0f3c787e978e142d2e2a4aa65fea5f4c8550c8030b2d33cbd8f0afc2f2a4f540dcb38dfa3e1a6" +
        "e6fe9c45c6a59bc0644ef347056175c4be4c56a29741fa40512f391730c5ea38a56429741cc552d841f2c7cf59ff2c6c" +
        "60695489c93f47fff9a891a5e69de41d398bad0b0fe153c11633c568c6")

    func testBytesRoundTripWithoutLeadingZeros() {
        XCTAssertEqual(MegaBigInt(Data([0, 0, 1, 2])).data, Data([1, 2]), "El número no guarda los ceros de cabecera")
        XCTAssertTrue(MegaBigInt(Data([0, 0])).isZero)
        XCTAssertEqual(MegaBigInt(Data()).data, Data())
        XCTAssertEqual(MegaBigInt(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01])).data, Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01]),
                       "Un valor que cruza el límite de 32 bits vuelve igual")
        XCTAssertEqual(MegaBigInt(Data([1, 0, 0, 0, 0])).bitWidth, 33)
    }

    func testMultiplicationMatchesTheKnownModulus() {
        let n = number("87cfe04f5be787df22ef119fe1761084bfbdad13908b49106e260600f0fa6fca3a2e6d9d789e0d9c062705888a51a21b2a0798f2a3e46fb8e72afaef148f5b2bd075a90127493c0dc425f483226b0a4b6b8496362980087b8c2318d6d93c72fa4cb4e5b6b3ec2948dacf370d19123805240fab60f81476c3e651c29ca10f8491ff83950a120f4dba269f57fa5b616882b74ced676cb1fb91bc582a1239dca9895de8b893abd05e0bb720b4389bea43618cb6dc4360d0574b083680ab6b2035a80038d542e9586f2d29fa713e201b517b3d93e4155b23bb73ef0a97f808fb3354b3e2ec75aacdf15a55dd96536360072d4afdf977eec3d945fa6ee7395422df6f")
        XCTAssertEqual(p * q, n)
        XCTAssertEqual(q * p, n, "El producto no depende del orden, que en Mega llega cambiado")
        XCTAssertTrue((p * MegaBigInt(0)).isZero)
    }

    func testModularExponentiationMatchesAReferenceImplementation() throws {
        let small = try XCTUnwrap(MegaMontgomery(modulus: number("1f1")))
        XCTAssertEqual(hex(small.power(base: number("4"), exponent: number("d"))), "1bd", "4^13 mod 497")

        let wide = try XCTUnwrap(MegaMontgomery(modulus: number("fffffffffffffffffffffffffffffffd")))
        XCTAssertEqual(hex(wide.power(base: number("2"), exponent: number("800"))), "290d741")

        // An even modulus has no inverse mod 2^32, so Montgomery cannot be set up; RSA moduli are always odd.
        XCTAssertNil(MegaMontgomery(modulus: number("100")))
    }

    func testTheRSAStepOfSignInRecoversTheChallenge() throws {
        let montgomery = try XCTUnwrap(MegaMontgomery(modulus: p * q))
        let recovered = montgomery.power(base: ciphertext, exponent: d)
        XCTAssertEqual(recovered, plaintext, "Descifrar con la clave privada devuelve el desafío original")
    }

    func testExponentiationIsFastEnoughToRunOnEverySignIn() throws {
        let montgomery = try XCTUnwrap(MegaMontgomery(modulus: p * q))
        let started = Date()
        _ = montgomery.power(base: ciphertext, exponent: d)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "Una exponenciación de 2048 bits no debe tardar segundos")
    }
}
