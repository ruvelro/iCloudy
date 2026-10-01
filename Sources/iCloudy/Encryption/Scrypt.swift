import Foundation
import CommonCrypto

/// scrypt (RFC 7914), the key derivation Cryptomator puts in front of every vault's masterkey. CommonCrypto has
/// PBKDF2 but not scrypt, and the app takes no dependencies, so the memory-hard middle is written here: Salsa20/8,
/// BlockMix and ROMix, on 32-bit words. It runs on every unlock with N = 32768 and r = 8, which is 32 MiB and a
/// million Salsa20/8 cores, so the inner loop keeps its state in locals and works on raw pointers: an array-indexed
/// version spent most of its time in bounds checks when compiled for debugging.
enum Scrypt {
    enum Failure: Error, Equatable { case invalidParameters, derivationFailed }

    /// Memory a hostile masterkey file may ask for before it is refused. Cryptomator's default needs 32 MiB.
    static let memoryLimit = 512 * 1024 * 1024

    static func derive(password: [UInt8], salt: [UInt8], n: Int, r: Int, p: Int, length: Int) throws -> [UInt8] {
        // N must be a power of two above one; the products are bounded before anything is allocated.
        guard n > 1, n & (n - 1) == 0, r > 0, p > 0, p <= 64, length > 0,
              r <= memoryLimit / 128, n <= memoryLimit / (128 * r) else { throw Failure.invalidParameters }
        let blockBytes = 128 * r
        var b = try pbkdf2SHA256(password: password, salt: salt, iterations: 1, length: p * blockBytes)
        for index in 0..<p {
            let start = index * blockBytes
            var block = Array(b[start..<(start + blockBytes)])
            roMix(&block, r: r, n: n)
            b.replaceSubrange(start..<(start + blockBytes), with: block)
        }
        return try pbkdf2SHA256(password: password, salt: b, iterations: 1, length: length)
    }

    static func pbkdf2SHA256(password: [UInt8], salt: [UInt8], iterations: Int, length: Int) throws -> [UInt8] {
        var output = [UInt8](repeating: 0, count: length)
        // CommonCrypto refuses a null pointer even with a zero length, and an empty array has no base address.
        let passwordBytes = password.isEmpty ? [UInt8(0)] : password
        let saltBytes = salt.isEmpty ? [UInt8(0)] : salt
        let status = passwordBytes.withUnsafeBufferPointer { pass in
            saltBytes.withUnsafeBufferPointer { saltPointer in
                output.withUnsafeMutableBufferPointer { out in
                    pass.baseAddress!.withMemoryRebound(to: Int8.self, capacity: pass.count) { passChars in
                        CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passChars, password.count,
                                             saltPointer.baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                             UInt32(iterations), out.baseAddress, length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.derivationFailed }
        return output
    }

    /// scryptROMix over one block of 128·r bytes, in place.
    static func roMix(_ block: inout [UInt8], r: Int, n: Int) {
        let words = 32 * r
        var x = [UInt32](repeating: 0, count: words)
        for i in 0..<words {
            x[i] = UInt32(block[4 * i]) | UInt32(block[4 * i + 1]) << 8 | UInt32(block[4 * i + 2]) << 16 | UInt32(block[4 * i + 3]) << 24
        }
        var v = [UInt32](repeating: 0, count: words * n)
        var scratch = [UInt32](repeating: 0, count: words)
        let mask = UInt32(truncatingIfNeeded: n - 1)
        x.withUnsafeMutableBufferPointer { xp in
            v.withUnsafeMutableBufferPointer { vp in
                scratch.withUnsafeMutableBufferPointer { sp in
                    let x = xp.baseAddress!, v = vp.baseAddress!, s = sp.baseAddress!
                    for i in 0..<n {
                        (v + i * words).update(from: x, count: words)
                        blockMix(x, scratch: s, r: r)
                    }
                    for _ in 0..<n {
                        // Integerify: the first word of the last 64-byte block, little-endian; N fits in 32 bits.
                        let j = Int(x[(2 * r - 1) * 16] & mask)
                        let row = v + j * words
                        for k in 0..<words { x[k] ^= row[k] }
                        blockMix(x, scratch: s, r: r)
                    }
                }
            }
        }
        for i in 0..<words {
            let word = x[i]
            block[4 * i] = UInt8(truncatingIfNeeded: word); block[4 * i + 1] = UInt8(truncatingIfNeeded: word >> 8)
            block[4 * i + 2] = UInt8(truncatingIfNeeded: word >> 16); block[4 * i + 3] = UInt8(truncatingIfNeeded: word >> 24)
        }
    }

    /// scryptBlockMix: Salsa20/8 chained over the 2r 64-byte blocks, even outputs first and odd ones after.
    static func blockMix(_ b: UnsafeMutablePointer<UInt32>, scratch y: UnsafeMutablePointer<UInt32>, r: Int) {
        var t = (UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0),
                 UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0), UInt32(0))
        withUnsafeMutableBytes(of: &t) { raw in
            let x = raw.baseAddress!.assumingMemoryBound(to: UInt32.self)
            x.update(from: b + (2 * r - 1) * 16, count: 16)
            for i in 0..<(2 * r) {
                let block = b + i * 16
                for k in 0..<16 { x[k] ^= block[k] }
                salsa20_8(x)
                // Y_i goes to position i/2 when even, r + i/2 when odd.
                (y + ((i & 1) * r + (i >> 1)) * 16).update(from: x, count: 16)
            }
        }
        b.update(from: y, count: 32 * r)
    }

    /// The Salsa20/8 core of RFC 7914 §3, in place on sixteen words.
    static func salsa20_8(_ b: UnsafeMutablePointer<UInt32>) {
        var x0 = b[0], x1 = b[1], x2 = b[2], x3 = b[3], x4 = b[4], x5 = b[5], x6 = b[6], x7 = b[7]
        var x8 = b[8], x9 = b[9], x10 = b[10], x11 = b[11], x12 = b[12], x13 = b[13], x14 = b[14], x15 = b[15]
        @inline(__always) func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value << count) | (value >> (32 - count)) }
        for _ in 0..<4 {
            // Columns.
            x4 ^= rotate(x0 &+ x12, 7); x8 ^= rotate(x4 &+ x0, 9); x12 ^= rotate(x8 &+ x4, 13); x0 ^= rotate(x12 &+ x8, 18)
            x9 ^= rotate(x5 &+ x1, 7); x13 ^= rotate(x9 &+ x5, 9); x1 ^= rotate(x13 &+ x9, 13); x5 ^= rotate(x1 &+ x13, 18)
            x14 ^= rotate(x10 &+ x6, 7); x2 ^= rotate(x14 &+ x10, 9); x6 ^= rotate(x2 &+ x14, 13); x10 ^= rotate(x6 &+ x2, 18)
            x3 ^= rotate(x15 &+ x11, 7); x7 ^= rotate(x3 &+ x15, 9); x11 ^= rotate(x7 &+ x3, 13); x15 ^= rotate(x11 &+ x7, 18)
            // Rows.
            x1 ^= rotate(x0 &+ x3, 7); x2 ^= rotate(x1 &+ x0, 9); x3 ^= rotate(x2 &+ x1, 13); x0 ^= rotate(x3 &+ x2, 18)
            x6 ^= rotate(x5 &+ x4, 7); x7 ^= rotate(x6 &+ x5, 9); x4 ^= rotate(x7 &+ x6, 13); x5 ^= rotate(x4 &+ x7, 18)
            x11 ^= rotate(x10 &+ x9, 7); x8 ^= rotate(x11 &+ x10, 9); x9 ^= rotate(x8 &+ x11, 13); x10 ^= rotate(x9 &+ x8, 18)
            x12 ^= rotate(x15 &+ x14, 7); x13 ^= rotate(x12 &+ x15, 9); x14 ^= rotate(x13 &+ x12, 13); x15 ^= rotate(x14 &+ x13, 18)
        }
        b[0] &+= x0; b[1] &+= x1; b[2] &+= x2; b[3] &+= x3; b[4] &+= x4; b[5] &+= x5; b[6] &+= x6; b[7] &+= x7
        b[8] &+= x8; b[9] &+= x9; b[10] &+= x10; b[11] &+= x11; b[12] &+= x12; b[13] &+= x13; b[14] &+= x14; b[15] &+= x15
    }
}
