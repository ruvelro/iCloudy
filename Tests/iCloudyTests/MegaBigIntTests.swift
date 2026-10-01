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

    /// The whole RSA step of a sign-in, setup included. It takes around 50 ms in a debug build on Apple Silicon; the
    /// limit leaves room for a slow CI machine while still catching a return to the seconds it used to take.
    func testExponentiationIsFastEnoughToRunOnEverySignIn() throws {
        let modulus = p * q
        let started = Date()
        let montgomery = try XCTUnwrap(MegaMontgomery(modulus: modulus))
        _ = montgomery.power(base: ciphertext, exponent: d)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "Una exponenciación de 2048 bits no debe tardar ni un segundo")
    }

    // MARK: - Cross-checks

    /// Two vectors computed with Python's built-in pow, independent of both iCloudy and OpenSSL. The first has a base
    /// wider than the modulus and a full 2048-bit exponent, so it walks the largest window; the second has a limb
    /// count that is not a power of two.
    func testExponentiationMatchesIndependentVectors() throws {
        let modulus = number("9f4915547cdd48dda43847ce9780271663b2599273144f180e877968bad1f704d1d37c83b2133a6380f91ecf63628ff7" +
            "5c31d4412f634fdf73df01f87ad9342843562f72bf9b44383f98f1bb8c9e51d5ce8567493b22e7dedc4bcc230697b18c" +
            "50060e38340466fac2041ff7e990b3eace0bd65b6406d27dd0c95e2c411bff1244856780e2563e4b90913a1f31064483" +
            "572d2d7e36bf7fec610f65e67678cc692fcb5832e466e705098a4df022e3f570ad000eac13f329c0bbb0d683c286c20e" +
            "302f0ae02661ddfe99635f3e1fc4be40d2edd018cbf9952fe408726b64551fdfa1cc719db7052664941707dc8770f0b6" +
            "d75df7ee5c1faa9f52135cb13ccc38b7")
        let base = number("11ca2021cd3df572eb411b603af15bcafae56dc259ac7482cbc6bb0e131eae8b365edc3a418cb139e25e2cc3e042de77" +
            "be31050c3c2a77f1023e5771d577b55c999296e33ab440ae772a0eac2837fd310c23ec255f40a98c4159cea80e95d489" +
            "77335b43d1494f7fca59fa5f46c048855f87627cdb7487faff5682776eb9f9a6e10e81d2bf8f1a72bebf8cefd9828025" +
            "e72d1914de0550a739d0a9c49e0d3691316cb05117c32c5ec490ff1d677adbff67a2f07025e6b334efde92c2546b9554" +
            "eb2a6291a894070d20e53b358fbdc133764bb931008595178d15013f49b96b39077d6a94fc0f4a44edb74dfaf24793bb" +
            "d2aef0794c6dcc2215207b73ad86d286b26213df17d4c394aa71c6abc24062f12be2a9703585e33da9421190a808a3b7" +
            "87059be5559766f57cb482042a39bb71a349917c41c41a0de2fc2f48ed81e786ba40f1ba9b6711a1e30e162d747416b2" +
            "74f1a76c5fe71b2d0a056cffc83d7461ad5f4b7e70b161ea26f008ad4f23b9d437df601b91e6b0")
        let exponent = number("8b7caf64670e80ef9e247801e1c75423043085b3381dc88738c11c05f39c50ca999f57cfa1b489e609169ffdca1b3df9" +
            "407388aa66defc3dd025ea9eeede281352ee6543ed90916d889e9b1f23ee5d619a3cd64cd39ebc2dae6033c5b14e60af" +
            "2de7bfdfa9ae2ae4f70b7bae2ee862e0c16683e02e98d91e7978f0df74d5d58cdfd6d29f198fceaf29698004471ab649" +
            "b13c2bc627e08cfe8a0d716334ed765a8f615618cfca16d78b80d0b1a1b6623198e970c85cab94eada1107fbf0b9498a" +
            "f3d409b65a10dc7e840e5bca325d34f52fe269cd3820b09e4f201ad2b68bbeb68d54a07db07de339fcf63f58ccc8c0c3" +
            "78435b2d2ef0f8e8d41cb1923bd3d84f")
        let expected = number("6e43295f6af946802ede4cb0c62b0db0d4224dc0a2fa65f2f8eb6b389dff8243b47db82692068528e00f47bd49ec28a1" +
            "fcdbf7e4f5a401042cbd8a21fbfab47bfdf6388a35f16059cc2ec4058cc30fdd471b45d7b3896690b13fe068d175d909" +
            "f6e6f1a7756c4543585fcf9e726a602ccde25bf91f30a68bc3525c575aac887df0079988819dd2abc7acec58f5bc50f9" +
            "d2fe1391502e4f7b50ad288f4f31b2fd5dd7c08366c92e8da64fb9869c71c2fbc600f525f5000e6360a481dfdb60e699" +
            "b00bd7162220bdcf9482e2580a24086889a81075a4e1950f731c8ad83030ea7737e116bb782a6345a34c90c3033f177b" +
            "2291c68e0be96bcd04ba0445b003296b")
        XCTAssertEqual(try XCTUnwrap(MegaMontgomery(modulus: modulus)).power(base: base, exponent: exponent), expected,
                       "Una base más ancha que el módulo se reduce antes de exponenciar")

        let odd = number("9b97c446d2af01a32e59d3050cd9f7a52a8b84b1a65ec2f1c436650d7f81a2b9ef5d7b5d37e4b14784f44780d9165de1" +
            "d03349d7df2967603278e773d3e32d734eba11b59b3eb5191a5ce5d00565d9297a0d6d83a820a59ef747a5796626f228" +
            "7880831b41fbd943ccde8439f8761f9d17f11b883990eed86cbe7ebba3")
        let oddBase = number("23b6c7ba6410e09a9e28f89ee6f8580cb8a60a1728772c9eb4ebb8b295cd1ddcf24f92e837eecacac3564409eacc183f" +
            "1d2ccc4ea1076ff2e36dfcc8c35b6e00d5e091ad6659ae9d2579377e1d4c9d00174111dc924e40c09d8c2ba8de913ef4" +
            "12115a25199bff41fb565bd076a3f16926ff935a440946ab885ce02425")
        let oddExponent = number("8a9ffa4b06a2efecf865b586d802369ae8898894a80d7c534739925d8045f8803af6d2cadcc263ced57fcb18c104b0a9" +
            "f9dcf51c22f3a42e40ef7739d8abd4ef4ae2995d83f9a0c741497d28043bf4d14e5a62879aceb1a8618f72d5ec631d0c" +
            "088d74b745dc63e3951386f43641450a0d1e178d1276f55ba52fe06b3f")
        let oddExpected = number("38de357ab0d8412edd82b39c856cab7803bae64ee9749fd3fdf3a69273710402ff59742db822b9a20d38b379d21984f8" +
            "1a42c4b31b446cad94dced1ebe9d5dde4c7eb5ec76aaa5309398222d27a85a8a804303b590d0d0eaeca7a825ae596f54" +
            "641c4c74511fbfb96b546e5a7a02b367b71fa31d52dcdc44b16acf75b9")
        XCTAssertEqual(try XCTUnwrap(MegaMontgomery(modulus: odd)).power(base: oddBase, exponent: oddExponent), oddExpected)
    }

    func testBytesAndProductsMatchTheReferenceForManySizes() {
        var random = SplitMix(seed: 0x6D65_6761)
        for round in 0..<300 {
            // Leading zero bytes on purpose: they must vanish, whether or not they fill a whole limb.
            let zeros = Int.random(in: 0...12, using: &random)
            let left = Data(repeating: 0, count: zeros) + random.bytes(Int.random(in: 0...140, using: &random))
            let right = random.bytes(Int.random(in: 0...140, using: &random))
            let value = MegaBigInt(left)
            XCTAssertEqual(value.data, Data(left.drop { $0 == 0 }), "Vuelta de bytes, ronda \(round)")
            XCTAssertEqual(value.bitWidth, Reference.bitWidth(Reference.number(left)), "Anchura en bits, ronda \(round)")
            let expected = Reference.data(Reference.multiply(Reference.number(left), Reference.number(right)))
            XCTAssertEqual((value * MegaBigInt(right)).data, expected, "Producto, ronda \(round)")
        }
    }

    /// Random moduli of every awkward width, around each 32- and 64-bit limb boundary, against plain square and
    /// multiply. The exponents reach every window size (1, 3, 4, 5 and 6 bits); the wide ones stay on small moduli so
    /// the slow reference keeps the test quick.
    func testExponentiationMatchesTheReferenceForManySizes() throws {
        var random = SplitMix(seed: 0x5253_4121)
        let widths = [1, 2, 3, 7, 31, 32, 33, 63, 64, 65, 96, 127, 128, 129, 191, 192, 193, 255, 256, 257, 383, 448, 511, 512, 513,
                      767, 768, 769, 1023, 1024, 1025]
        for width in widths {
            for _ in 0..<2 {
                let modulus = random.odd(bits: width)
                let arithmetic = try XCTUnwrap(MegaMontgomery(modulus: modulus), "Módulo de \(width) bits")
                let longest = width <= 129 ? 672 : width <= 257 ? 240 : width <= 513 ? 80 : 24
                let exponents = [MegaBigInt(0), MegaBigInt(1), MegaBigInt(2), MegaBigInt(3)] +
                    [5, 24, 80, 240, 672].filter { $0 <= longest }.map { random.number(bits: $0, exact: true) }
                // One below the modulus and one up to three times as wide, which has to be reduced first.
                let bases = [random.number(bits: width - 1), random.number(bits: Int.random(in: 1...(3 * width + 70), using: &random))]
                for base in bases {
                    for exponent in exponents {
                        let expected = Reference.power(Reference.number(base.data), Reference.number(exponent.data),
                                                       Reference.number(modulus.data))
                        XCTAssertEqual(arithmetic.power(base: base, exponent: exponent).data, Reference.data(expected),
                                       "\(hex(base))^\(hex(exponent)) mod \(hex(modulus))")
                    }
                }
                // Bases whose answer is known without the reference: zero and its multiples, and one.
                let one = width == 1 ? MegaBigInt(0) : MegaBigInt(1)
                for exponent in exponents {
                    for zero in [MegaBigInt(0), modulus, modulus * MegaBigInt(3)] {
                        XCTAssertEqual(arithmetic.power(base: zero, exponent: exponent), exponent.isZero ? one : MegaBigInt(0),
                                       "\(hex(zero))^\(hex(exponent)) mod \(hex(modulus))")
                    }
                    XCTAssertEqual(arithmetic.power(base: MegaBigInt(1), exponent: exponent), one)
                }
            }
        }
    }

    func testEdgeCasesOfExponentiation() throws {
        let modulus = number("fffffffffffffffffffffffffffffffd")
        let arithmetic = try XCTUnwrap(MegaMontgomery(modulus: modulus))
        XCTAssertEqual(arithmetic.power(base: number("1234"), exponent: MegaBigInt(0)), MegaBigInt(1), "Exponente cero da uno")
        XCTAssertEqual(arithmetic.power(base: MegaBigInt(0), exponent: MegaBigInt(0)), MegaBigInt(1), "También con base cero")
        XCTAssertTrue(arithmetic.power(base: MegaBigInt(0), exponent: number("ffff")).isZero)
        XCTAssertEqual(arithmetic.power(base: number("1234"), exponent: MegaBigInt(1)), number("1234"))
        XCTAssertTrue(arithmetic.power(base: modulus, exponent: number("5")).isZero, "La base igual al módulo es cero")
        // 2²⁵⁶ + n + 1, two limbs wider than the modulus: 2¹²⁸ ≡ 3, so it reduces to 9 + 1.
        XCTAssertEqual(hex(arithmetic.power(base: number("1" + String(repeating: "0", count: 32) + "fffffffffffffffffffffffffffffffe"),
                                            exponent: MegaBigInt(1))), "a")

        // A modulus of one sends everything to zero, even an exponent of zero.
        let unit = try XCTUnwrap(MegaMontgomery(modulus: MegaBigInt(1)))
        XCTAssertTrue(unit.power(base: number("abc"), exponent: MegaBigInt(0)).isZero)
        XCTAssertTrue(unit.power(base: number("abc"), exponent: number("abc")).isZero)

        // Leading zero bytes in the encoded modulus, more than a whole limb of them, change nothing.
        let padded = try XCTUnwrap(MegaMontgomery(modulus: MegaBigInt(Data(repeating: 0, count: 9) + Data([0x01, 0xF1]))))
        XCTAssertEqual(hex(padded.power(base: number("4"), exponent: number("d"))), "1bd", "4^13 mod 497")
        // A modulus just past one limb, whose top limb is a single bit.
        let wide = try XCTUnwrap(MegaMontgomery(modulus: number("10000000000000001")))
        XCTAssertEqual(hex(wide.power(base: number("2"), exponent: number("40"))), "10000000000000000", "2⁶⁴ ≡ −1")
        XCTAssertEqual(hex(wide.power(base: number("2"), exponent: number("80"))), "1", "2¹²⁸ ≡ 1")
        XCTAssertNil(MegaMontgomery(modulus: MegaBigInt(0)), "Sin módulo no hay aritmética")
    }

    /// At full size the reference is too slow, so the checks are algebraic, and any slip in the windows or the
    /// reduction would break them: (aᵉ)ᶠ = a^(e·f), and a^(2e) = aᵉ · aᵉ.
    func testFullSizeExponentiationAgreesWithItself() throws {
        var random = SplitMix(seed: 0x2048)
        for width in [1024, 2048] {
            let modulus = random.odd(bits: width)
            let arithmetic = try XCTUnwrap(MegaMontgomery(modulus: modulus))
            let base = random.number(bits: width + 100)
            let first = random.number(bits: width / 2, exact: true), second = random.number(bits: width / 2, exact: true)
            XCTAssertEqual(arithmetic.power(base: arithmetic.power(base: base, exponent: first), exponent: second),
                           arithmetic.power(base: base, exponent: first * second), "(aᵉ)ᶠ = a^(e·f), \(width) bits")
            // The product is reduced by raising it to one.
            let half = arithmetic.power(base: base, exponent: first)
            XCTAssertEqual(arithmetic.power(base: half * half, exponent: MegaBigInt(1)),
                           arithmetic.power(base: base, exponent: first * MegaBigInt(2)), "a^(2e) = aᵉ · aᵉ, \(width) bits")
            let reduced = Reference.data(Reference.remainder(Reference.number(base.data), Reference.number(modulus.data)))
            XCTAssertEqual(arithmetic.power(base: base, exponent: MegaBigInt(1)).data, reduced, "a¹ es a reducido")
        }
    }
}

// MARK: - Reference

/// The arithmetic iCloudy used before it was made fast, kept as a yardstick: 32-bit limbs, schoolbook multiplication,
/// the remainder by binary long division and plain square and multiply. Slow and obviously right, and it shares
/// nothing with the code under test except the byte format.
private enum Reference {
    /// Little-endian 32-bit limbs with no leading zeros.
    typealias Number = [UInt32]

    static func number(_ data: Data) -> Number {
        let bytes = [UInt8](data)
        var result: Number = []
        var end = bytes.count
        while end > 0 {
            let start = max(0, end - 4)
            var limb: UInt32 = 0
            for byte in bytes[start..<end] { limb = limb << 8 | UInt32(byte) }
            result.append(limb)
            end = start
        }
        return trimmed(result)
    }
    static func data(_ number: Number) -> Data {
        var bytes: [UInt8] = []
        for limb in number.reversed() {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: limb >> 24), UInt8(truncatingIfNeeded: limb >> 16),
                                      UInt8(truncatingIfNeeded: limb >> 8), UInt8(truncatingIfNeeded: limb)])
        }
        while bytes.first == 0 { bytes.removeFirst() }
        return Data(bytes)
    }
    static func bitWidth(_ number: Number) -> Int {
        guard let top = number.last else { return 0 }
        return number.count * 32 - top.leadingZeroBitCount
    }

    static func multiply(_ left: Number, _ right: Number) -> Number {
        guard !left.isEmpty, !right.isEmpty else { return [] }
        var result = Number(repeating: 0, count: left.count + right.count)
        for (index, limb) in left.enumerated() {
            var carry: UInt64 = 0
            for (offset, other) in right.enumerated() {
                let value = UInt64(result[index + offset]) + UInt64(limb) * UInt64(other) + carry
                result[index + offset] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            var position = index + right.count
            while carry != 0 {
                let value = UInt64(result[position]) + carry
                result[position] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
                position += 1
            }
        }
        return trimmed(result)
    }

    /// value mod modulus, one bit at a time: shift the next bit in, subtract whenever the remainder reaches the modulus.
    /// Raw pointers and `while` loops only because a debug build made the randomized test take most of a minute.
    static func remainder(_ value: Number, _ modulus: Number) -> Number {
        let divisor = modulus + [0]
        var rest = Number(repeating: 0, count: divisor.count)
        rest.withUnsafeMutableBufferPointer { rest in
            divisor.withUnsafeBufferPointer { divisor in
                let rest = rest.baseAddress!, divisor = divisor.baseAddress!, count = modulus.count + 1
                var index = value.count * 32 - 1
                while index >= 0 {
                    var carry = value[index / 32] >> UInt32(index % 32) & 1
                    index -= 1
                    var limb = 0
                    while limb < count {
                        let next = rest[limb] >> 31
                        rest[limb] = rest[limb] << 1 | carry
                        carry = next
                        limb += 1
                    }
                    limb = count - 1
                    while limb > 0 && rest[limb] == divisor[limb] { limb -= 1 }
                    guard rest[limb] >= divisor[limb] else { continue }
                    var borrow: Int64 = 0
                    limb = 0
                    while limb < count {
                        let difference = Int64(rest[limb]) - Int64(divisor[limb]) - borrow
                        rest[limb] = UInt32(truncatingIfNeeded: difference)
                        borrow = difference < 0 ? 1 : 0
                        limb += 1
                    }
                }
            }
        }
        return trimmed(rest)
    }

    static func power(_ base: Number, _ exponent: Number, _ modulus: Number) -> Number {
        let base = remainder(base, modulus)
        var result = remainder([1], modulus)
        for index in stride(from: exponent.count * 32 - 1, through: 0, by: -1) {
            result = remainder(multiply(result, result), modulus)
            if exponent[index / 32] >> UInt32(index % 32) & 1 == 1 { result = remainder(multiply(result, base), modulus) }
        }
        return result
    }

    private static func trimmed(_ number: Number) -> Number {
        var number = number
        while number.last == 0 { number.removeLast() }
        return number
    }
}

/// A seeded generator, so a failing case can be replayed exactly.
private struct SplitMix: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ value >> 30) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ value >> 27) &* 0x94D0_49BB_1331_11EB
        return value ^ value >> 31
    }
    mutating func bytes(_ count: Int) -> Data { Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &self) }) }
    /// A random number below 2^bits; with `exact`, exactly `bits` wide.
    mutating func number(bits: Int, exact: Bool = false) -> MegaBigInt {
        guard bits > 0 else { return MegaBigInt(0) }
        var data = bytes((bits + 7) / 8)
        data[0] &= UInt8(truncatingIfNeeded: 0xFF >> ((8 - bits % 8) % 8))
        if exact { data[0] |= 1 << UInt8((bits - 1) % 8) }
        return MegaBigInt(data)
    }
    /// An odd number exactly `bits` wide, the shape of every modulus Montgomery accepts.
    mutating func odd(bits: Int) -> MegaBigInt {
        var data = number(bits: bits, exact: true).data
        data[data.count - 1] |= 1
        return MegaBigInt(data)
    }
}
