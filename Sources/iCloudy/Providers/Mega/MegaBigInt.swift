import Foundation

/// The only big-number arithmetic iCloudy needs: one modular exponentiation with a 2048-bit RSA key, which Mega asks
/// for once per sign-in to prove that the session belongs to whoever holds the account's private key.
///
/// The reduction uses Montgomery multiplication rather than long division. Division is the part of big-number
/// arithmetic that is easiest to get subtly wrong, and Montgomery needs only multiplication, shifts and comparisons.
/// Correctness comes first, since a wrong result means a login that fails without explanation, but speed matters too:
/// the exponentiation runs on every sign-in, and it has to stay quick even in a debug build, where array accesses are
/// checked and nothing is inlined. That is why the hot loops work on 64-bit limbs through raw pointers.
struct MegaBigInt: Equatable {
    /// Little-endian limbs: index 0 is the least significant. Zero is the empty array, and there are no leading zeros.
    private(set) var limbs: [UInt64]

    init(limbs: [UInt64]) { self.limbs = MegaBigInt.trimmed(limbs) }
    init(_ value: UInt32) { limbs = value == 0 ? [] : [UInt64(value)] }
    /// Reads a big-endian byte string, the way every value arrives from Mega.
    init(_ data: Data) {
        let bytes = [UInt8](data)
        var result: [UInt64] = []
        result.reserveCapacity((bytes.count + 7) / 8)
        var end = bytes.count
        while end > 0 {
            let start = max(0, end - 8)
            var limb: UInt64 = 0
            for byte in bytes[start..<end] { limb = limb << 8 | UInt64(byte) }
            result.append(limb)
            end = start
        }
        limbs = MegaBigInt.trimmed(result)
    }

    var isZero: Bool { limbs.isEmpty }
    /// Big-endian bytes with no leading zeros, which is what Mega's session identifier is cut from.
    var data: Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(limbs.count * 8)
        for limb in limbs.reversed() {
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: limb >> UInt64(shift))) }
        }
        let first = bytes.firstIndex { $0 != 0 } ?? bytes.count
        return Data(bytes[first...])
    }
    /// Bit at `index`, counting from the least significant.
    func bit(_ index: Int) -> Bool {
        let limb = index / 64
        guard index >= 0, limb < limbs.count else { return false }
        return limbs[limb] >> UInt64(index % 64) & 1 == 1
    }
    var bitWidth: Int {
        guard let top = limbs.last else { return 0 }
        return limbs.count * 64 - top.leadingZeroBitCount
    }

    static func * (left: MegaBigInt, right: MegaBigInt) -> MegaBigInt {
        guard !left.isZero, !right.isZero else { return MegaBigInt(0) }
        var result = [UInt64](repeating: 0, count: left.limbs.count + right.limbs.count)
        result.withUnsafeMutableBufferPointer { result in
            left.limbs.withUnsafeBufferPointer { left in
                right.limbs.withUnsafeBufferPointer { right in
                    let out = result.baseAddress!, a = left.baseAddress!, b = right.baseAddress!
                    let count = right.count
                    for index in 0..<left.count {
                        let limb = a[index]
                        var carry: UInt64 = 0
                        var offset = 0
                        while offset < count {
                            (carry, out[index + offset]) = multiplyAdd(limb, b[offset], out[index + offset], carry)
                            offset += 1
                        }
                        // Nothing has been written this high yet, so the carry lands on a zero limb.
                        out[index + count] = carry
                    }
                }
            }
        }
        return MegaBigInt(limbs: result)
    }

    /// a · b + c + d as a (high, low) pair. It cannot overflow: (2⁶⁴ − 1)² + 2 · (2⁶⁴ − 1) = 2¹²⁸ − 1.
    @inline(__always)
    private static func multiplyAdd(_ a: UInt64, _ b: UInt64, _ c: UInt64, _ d: UInt64) -> (high: UInt64, low: UInt64) {
        var (high, low) = a.multipliedFullWidth(by: b)
        var overflow: Bool
        (low, overflow) = low.addingReportingOverflow(c)
        if overflow { high &+= 1 }
        (low, overflow) = low.addingReportingOverflow(d)
        if overflow { high &+= 1 }
        return (high, low)
    }

    private static func trimmed(_ limbs: [UInt64]) -> [UInt64] {
        var limbs = limbs
        while limbs.last == 0 { limbs.removeLast() }
        return limbs
    }
}

/// Montgomery arithmetic for one odd modulus. Every RSA modulus is odd, so the requirement never bites in practice.
struct MegaMontgomery {
    private let modulus: [UInt64]
    private let count: Int
    /// -modulus⁻¹ mod 2⁶⁴, the value that makes each step's low limb cancel out.
    private let inverse: UInt64
    /// R² mod modulus, with R = 2^(64·limbs), which moves a number into Montgomery form.
    private let square: [UInt64]

    init?(modulus value: MegaBigInt) {
        guard let low = value.limbs.first, low & 1 == 1 else { return nil }
        modulus = value.limbs
        count = modulus.count
        // Newton's iteration doubles the number of correct bits each time, so six rounds cover all 64.
        var inverse: UInt64 = 1
        for _ in 0..<6 { inverse = inverse &* (2 &- low &* inverse) }
        self.inverse = 0 &- inverse
        // Doubling from one, 128·limbs times, reaches R² mod modulus without ever dividing. A modulus of one leaves
        // nothing but zero, and starting there keeps every value below it.
        var accumulator = [UInt64](repeating: 0, count: count)
        accumulator[0] = count == 1 && low == 1 ? 0 : 1
        let count = count
        modulus.withUnsafeBufferPointer { modulus in
            accumulator.withUnsafeMutableBufferPointer { accumulator in
                let value = accumulator.baseAddress!, modulus = modulus.baseAddress!
                for _ in 0..<(128 * count) {
                    var carry: UInt64 = 0
                    var index = 0
                    while index < count {
                        let next = value[index] >> 63
                        value[index] = value[index] << 1 | carry
                        carry = next
                        index += 1
                    }
                    // A carry out means the doubled value passed R, which is already larger than the modulus.
                    if carry != 0 || !MegaMontgomery.isBelow(value, modulus, count) {
                        MegaMontgomery.subtract(value, modulus, count)
                    }
                }
            }
        }
        square = accumulator
    }

    /// base^exponent mod modulus. A sliding window over the exponent's bits from the top down: the odd powers of the
    /// base up to the window size are computed once, and each window then costs one multiplication instead of one
    /// per set bit. The base may be any size, including larger than the modulus.
    func power(base: MegaBigInt, exponent: MegaBigInt) -> MegaBigInt {
        let count = count
        let bits = exponent.bitWidth
        // The usual window sizes for each exponent length: past a point the table costs more than the windows save.
        let window = bits > 671 ? 6 : bits > 239 ? 5 : bits > 79 ? 4 : bits > 23 ? 3 : 1
        let entries = 1 << (window - 1)
        // One allocation for the whole exponentiation: the table of odd powers, the running result, the base squared,
        // a one, a staging area for the base (`count` limbs each) and the multiplication's scratch row (`count` + 2).
        let size = entries * count + 4 * count + (count + 2)
        let workspace = UnsafeMutablePointer<UInt64>.allocate(capacity: size)
        workspace.initialize(repeating: 0, count: size)
        defer { workspace.deallocate() }
        let table = workspace, result = table + entries * count, squared = result + count, one = squared + count
        let staging = one + count, scratch = staging + count
        one[0] = 1

        return modulus.withUnsafeBufferPointer { modulus in
            square.withUnsafeBufferPointer { square in
                let kernel = Kernel(modulus: modulus.baseAddress!, count: count, inverse: inverse, scratch: scratch)
                let square = square.baseAddress!

                // The base into Montgomery form, Horner's rule over blocks of `count` limbs from the top: each step
                // multiplies what came before by R and adds the next block times R, both modulo the modulus. Any
                // block below R times R² stays under modulus · R, which is all a Montgomery product asks for.
                base.limbs.withUnsafeBufferPointer { limbs in
                    let blocks = (limbs.count + count - 1) / count
                    for block in stride(from: blocks - 1, through: 0, by: -1) {
                        if block != blocks - 1 { kernel.multiply(table, table, square) }
                        let start = block * count, length = min(count, limbs.count - start)
                        staging.update(repeating: 0, count: count)
                        staging.update(from: limbs.baseAddress! + start, count: length)
                        kernel.multiply(staging, staging, square)
                        kernel.addModulo(table, staging)
                    }
                }
                if entries > 1 {
                    kernel.multiply(squared, table, table)
                    for entry in 1..<entries {
                        kernel.multiply(table + entry * count, table + (entry - 1) * count, squared)
                    }
                }

                // One in Montgomery form, which is what an exponent of zero leaves behind.
                kernel.multiply(result, one, square)
                var started = false
                var index = bits - 1
                while index >= 0 {
                    guard exponent.bit(index) else {
                        if started { kernel.multiply(result, result, result) }
                        index -= 1
                        continue
                    }
                    // The longest window that starts here and ends on a set bit, so its value is odd.
                    var low = max(index - window + 1, 0)
                    while !exponent.bit(low) { low += 1 }
                    var value = 0
                    for position in stride(from: index, through: low, by: -1) { value = value << 1 | (exponent.bit(position) ? 1 : 0) }
                    let entry = table + (value >> 1) * count
                    if started {
                        for _ in low...index { kernel.multiply(result, result, result) }
                        kernel.multiply(result, result, entry)
                    } else {
                        // Squaring a one changes nothing, so the first window just copies its power.
                        result.update(from: entry, count: count)
                        started = true
                    }
                    index = low - 1
                }
                // Multiplying by a plain one divides by R, which takes the result back out of Montgomery form.
                kernel.multiply(result, result, one)
                return MegaBigInt(limbs: Array(UnsafeBufferPointer(start: result, count: count)))
            }
        }
    }

    /// The pointers one exponentiation works on, so the inner loops index raw memory instead of checked arrays.
    ///
    /// The loops in here are `while` loops on purpose, and the multiply-and-add is written out instead of calling
    /// `MegaBigInt.multiplyAdd`. In a debug build a `for` over a range goes through the iterator protocol on every
    /// step and nothing is inlined, which made the same code more than ten times slower.
    private struct Kernel {
        let modulus: UnsafePointer<UInt64>
        let count: Int
        let inverse: UInt64
        /// count + 2 limbs: the row being accumulated, plus the two limbs it can carry into.
        let scratch: UnsafeMutablePointer<UInt64>

        /// out = left · right · R⁻¹ mod modulus, interleaving each row of the product with one step of the reduction
        /// (CIOS). It needs left · right < modulus · R, which holds whenever both are reduced. `out` may be either
        /// input: everything accumulates in the scratch row and is copied out at the end.
        func multiply(_ out: UnsafeMutablePointer<UInt64>, _ left: UnsafePointer<UInt64>, _ right: UnsafePointer<UInt64>) {
            let total = scratch, count = count, modulus = modulus, inverse = inverse
            total.update(repeating: 0, count: count + 2)
            var index = 0
            while index < count {
                // total += left · right[index]
                let limb = right[index]
                var carry: UInt64 = 0
                var offset = 0
                while offset < count {
                    let (high, low) = left[offset].multipliedFullWidth(by: limb)
                    let (partial, first) = low.addingReportingOverflow(total[offset])
                    let (sum, second) = partial.addingReportingOverflow(carry)
                    total[offset] = sum
                    // Cannot overflow: (2⁶⁴ − 1)² + 2 · (2⁶⁴ − 1) = 2¹²⁸ − 1.
                    carry = high &+ (first ? 1 : 0) &+ (second ? 1 : 0)
                    offset += 1
                }
                let (top, overflow) = total[count].addingReportingOverflow(carry)
                total[count] = top
                total[count + 1] = overflow ? 1 : 0

                // total = (total + factor · modulus) / 2⁶⁴: the factor clears the low limb, so the row shifts down.
                let factor = total[0] &* inverse
                let (high, low) = factor.multipliedFullWidth(by: modulus[0])
                carry = high &+ (low.addingReportingOverflow(total[0]).overflow ? 1 : 0)
                offset = 1
                while offset < count {
                    let (high, low) = factor.multipliedFullWidth(by: modulus[offset])
                    let (partial, first) = low.addingReportingOverflow(total[offset])
                    let (sum, second) = partial.addingReportingOverflow(carry)
                    total[offset - 1] = sum
                    carry = high &+ (first ? 1 : 0) &+ (second ? 1 : 0)
                    offset += 1
                }
                let (shifted, carried) = total[count].addingReportingOverflow(carry)
                total[count - 1] = shifted
                total[count] = total[count + 1] &+ (carried ? 1 : 0)
                index += 1
            }
            // The result is below twice the modulus, so one subtraction is always enough.
            if total[count] != 0 || !MegaMontgomery.isBelow(total, modulus, count) {
                MegaMontgomery.subtract(total, modulus, count)
            }
            out.update(from: total, count: count)
        }

        /// value = (value + other) mod modulus, with both already reduced.
        func addModulo(_ value: UnsafeMutablePointer<UInt64>, _ other: UnsafePointer<UInt64>) {
            var carry = false
            var index = 0
            while index < count {
                let (partial, first) = value[index].addingReportingOverflow(other[index])
                let (sum, second) = partial.addingReportingOverflow(carry ? 1 : 0)
                value[index] = sum
                carry = first || second
                index += 1
            }
            if carry || !MegaMontgomery.isBelow(value, modulus, count) { MegaMontgomery.subtract(value, modulus, count) }
        }
    }

    private static func isBelow(_ value: UnsafePointer<UInt64>, _ other: UnsafePointer<UInt64>, _ count: Int) -> Bool {
        var index = count - 1
        while index >= 0 {
            if value[index] != other[index] { return value[index] < other[index] }
            index -= 1
        }
        return false
    }
    /// value -= other over `count` limbs. A borrow out of the top is dropped on purpose: callers only subtract when
    /// the true value, including any limb above `count`, is at least `other`.
    private static func subtract(_ value: UnsafeMutablePointer<UInt64>, _ other: UnsafePointer<UInt64>, _ count: Int) {
        var borrow = false
        var index = 0
        while index < count {
            let (partial, first) = value[index].subtractingReportingOverflow(other[index])
            let (difference, second) = partial.subtractingReportingOverflow(borrow ? 1 : 0)
            value[index] = difference
            borrow = first || second
            index += 1
        }
    }
}
