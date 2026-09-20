import Foundation

/// The only big-number arithmetic iCloudy needs: one modular exponentiation with a 2048-bit RSA key, which Mega asks
/// for once per sign-in to prove that the session belongs to whoever holds the account's private key.
///
/// The reduction uses Montgomery multiplication rather than long division. Division is the part of big-number
/// arithmetic that is easiest to get subtly wrong, and Montgomery needs only multiplication, shifts and comparisons.
/// Speed is irrelevant here, correctness is not: a wrong result means a login that fails without explanation.
struct MegaBigInt: Equatable {
    /// Little-endian limbs: index 0 is the least significant. Zero is the empty array, and there are no leading zeros.
    private(set) var limbs: [UInt32]

    init(limbs: [UInt32]) { self.limbs = MegaBigInt.trimmed(limbs) }
    init(_ value: UInt32) { limbs = value == 0 ? [] : [value] }
    /// Reads a big-endian byte string, the way every value arrives from Mega.
    init(_ data: Data) {
        let bytes = [UInt8](data)
        var result: [UInt32] = []
        var end = bytes.count
        while end > 0 {
            let start = max(0, end - 4)
            var limb: UInt32 = 0
            for byte in bytes[start..<end] { limb = limb << 8 | UInt32(byte) }
            result.append(limb)
            end = start
        }
        limbs = MegaBigInt.trimmed(result)
    }

    var isZero: Bool { limbs.isEmpty }
    /// Big-endian bytes with no leading zeros, which is what Mega's session identifier is cut from.
    var data: Data {
        var bytes: [UInt8] = []
        for limb in limbs.reversed() {
            bytes.append(contentsOf: [UInt8(truncatingIfNeeded: limb >> 24), UInt8(truncatingIfNeeded: limb >> 16),
                                      UInt8(truncatingIfNeeded: limb >> 8), UInt8(truncatingIfNeeded: limb)])
        }
        while bytes.first == 0 { bytes.removeFirst() }
        return Data(bytes)
    }
    /// Bit at `index`, counting from the least significant.
    func bit(_ index: Int) -> Bool {
        let limb = index / 32
        guard limb < limbs.count else { return false }
        return limbs[limb] >> UInt32(index % 32) & 1 == 1
    }
    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 32 - top.leadingZeroBitCount
    }

    static func * (left: MegaBigInt, right: MegaBigInt) -> MegaBigInt {
        guard !left.isZero, !right.isZero else { return MegaBigInt(0) }
        var result = [UInt32](repeating: 0, count: left.limbs.count + right.limbs.count)
        for (index, limb) in left.limbs.enumerated() {
            var carry: UInt64 = 0
            for (offset, other) in right.limbs.enumerated() {
                let value = UInt64(result[index + offset]) + UInt64(limb) * UInt64(other) + carry
                result[index + offset] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            var position = index + right.limbs.count
            while carry != 0 {
                let value = UInt64(result[position]) + carry
                result[position] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
                position += 1
            }
        }
        return MegaBigInt(limbs: result)
    }

    private static func trimmed(_ limbs: [UInt32]) -> [UInt32] {
        var limbs = limbs
        while limbs.last == 0 { limbs.removeLast() }
        return limbs
    }
}

/// Montgomery arithmetic for one odd modulus. Every RSA modulus is odd, so the requirement never bites in practice.
struct MegaMontgomery {
    private let modulus: [UInt32]
    private let count: Int
    /// -modulus⁻¹ mod 2³², the value that makes each step's low limb cancel out.
    private let inverse: UInt32
    /// 2^(64·limbs) mod modulus, which moves a number into Montgomery form.
    private let square: [UInt32]

    init?(modulus value: MegaBigInt) {
        guard let low = value.limbs.first, low & 1 == 1 else { return nil }
        modulus = value.limbs
        count = modulus.count
        // Newton's iteration doubles the number of correct bits each time, so five rounds cover all 32.
        var inverse: UInt32 = 1
        for _ in 0..<5 { inverse = inverse &* (2 &- low &* inverse) }
        self.inverse = 0 &- inverse
        // Doubling from one, 64·limbs times, reaches 2^(64·limbs) mod modulus without ever dividing.
        var accumulator = [UInt32](repeating: 0, count: count)
        accumulator[0] = 1
        for _ in 0..<(64 * count) { MegaMontgomery.double(&accumulator, modulus) }
        square = accumulator
    }

    /// left · right · R⁻¹ mod modulus, with both inputs already reduced.
    private func multiply(_ left: [UInt32], _ right: [UInt32]) -> [UInt32] {
        var total = [UInt32](repeating: 0, count: count + 2)
        for index in 0..<count {
            var carry: UInt64 = 0
            for offset in 0..<count {
                let value = UInt64(total[offset]) + UInt64(left[index]) * UInt64(right[offset]) + carry
                total[offset] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            var wide = UInt64(total[count]) + carry
            total[count] = UInt32(truncatingIfNeeded: wide)
            total[count + 1] = UInt32(truncatingIfNeeded: wide >> 32)

            let factor = UInt32(truncatingIfNeeded: UInt64(total[0]) &* UInt64(inverse))
            carry = (UInt64(total[0]) + UInt64(factor) * UInt64(modulus[0])) >> 32
            for offset in 1..<count {
                let value = UInt64(total[offset]) + UInt64(factor) * UInt64(modulus[offset]) + carry
                total[offset - 1] = UInt32(truncatingIfNeeded: value)
                carry = value >> 32
            }
            wide = UInt64(total[count]) + carry
            total[count - 1] = UInt32(truncatingIfNeeded: wide)
            total[count] = total[count + 1] &+ UInt32(truncatingIfNeeded: wide >> 32)
            total[count + 1] = 0
        }
        var result = Array(total[0..<count])
        if total[count] != 0 || !MegaMontgomery.isBelow(result, modulus) { MegaMontgomery.subtract(&result, modulus) }
        return result
    }

    /// base^exponent mod modulus, square and multiply over the exponent's bits from the top down.
    func power(base: MegaBigInt, exponent: MegaBigInt) -> MegaBigInt {
        var padded = base.limbs
        padded.append(contentsOf: [UInt32](repeating: 0, count: max(0, count - padded.count)))
        if !MegaMontgomery.isBelow(padded, modulus) { MegaMontgomery.subtract(&padded, modulus) }
        let form = multiply(Array(padded[0..<count]), square)

        var one = [UInt32](repeating: 0, count: count); one[0] = 1
        var result = multiply(one, square)
        var index = exponent.bitWidth - 1
        while index >= 0 {
            result = multiply(result, result)
            if exponent.bit(index) { result = multiply(result, form) }
            index -= 1
        }
        return MegaBigInt(limbs: multiply(result, one))
    }

    private static func double(_ value: inout [UInt32], _ modulus: [UInt32]) {
        var carry: UInt32 = 0
        for index in 0..<value.count {
            let next = value[index] >> 31
            value[index] = value[index] << 1 | carry
            carry = next
        }
        // A carry out means the doubled value passed 2^(32·limbs), which is already larger than the modulus.
        if carry != 0 || !isBelow(value, modulus) { subtract(&value, modulus) }
    }
    private static func isBelow(_ value: [UInt32], _ other: [UInt32]) -> Bool {
        for index in stride(from: value.count - 1, through: 0, by: -1) where value[index] != other[index] {
            return value[index] < other[index]
        }
        return false
    }
    private static func subtract(_ value: inout [UInt32], _ other: [UInt32]) {
        var borrow: UInt64 = 0
        for index in 0..<value.count {
            let difference = UInt64(value[index]) &- UInt64(other[index]) &- borrow
            value[index] = UInt32(truncatingIfNeeded: difference)
            borrow = difference >> 63
        }
    }
}
