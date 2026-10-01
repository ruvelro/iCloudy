import Foundation
import CommonCrypto

/// The AES constructions Cryptomator needs and CommonCrypto does not name: CMAC (RFC 4493), SIV (RFC 5297) and key
/// wrap (RFC 3394). All three are built on the single-block cipher from CommonCrypto, so the only thing taken on
/// trust is AES itself. Counter mode is done here too, over the full 128-bit counter as Java's `AES/CTR` does, rather
/// than relying on how a library chooses to carry between the halves of the block.
enum AESModes {
    enum Failure: Error, Equatable { case cipher, unauthentic, malformed }

    // MARK: - Block cipher

    /// AES in ECB over whole blocks, encrypting or decrypting. ECB appears only as the block primitive for the modes below.
    static func ecb(_ data: [UInt8], key: [UInt8], encrypt: Bool = true) throws -> [UInt8] {
        guard data.count % 16 == 0, [16, 24, 32].contains(key.count) else { throw Failure.cipher }
        if data.isEmpty { return [] }
        var output = [UInt8](repeating: 0, count: data.count)
        var moved = 0
        let status = CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                             key, key.count, nil, data, data.count, &output, output.count, &moved)
        guard status == kCCSuccess, moved == data.count else { throw Failure.cipher }
        return output
    }

    /// AES-CTR with `iv` as the initial 128-bit big-endian counter.
    static func ctr(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
        guard iv.count == 16 else { throw Failure.cipher }
        if data.isEmpty { return [] }
        let blocks = (data.count + 15) / 16
        var counters = [UInt8](repeating: 0, count: blocks * 16)
        var counter = iv
        for block in 0..<blocks {
            counters.replaceSubrange((block * 16)..<(block * 16 + 16), with: counter)
            // Increment the whole block as one big-endian number.
            var index = 15
            while index >= 0 { counter[index] &+= 1; if counter[index] != 0 { break }; index -= 1 }
        }
        let stream = try ecb(counters, key: key)
        var output = data
        for i in 0..<data.count { output[i] ^= stream[i] }
        return output
    }

    // MARK: - CMAC (RFC 4493)

    /// Multiplication by x in GF(2^128), the "dbl" of RFC 5297.
    static func double(_ block: [UInt8]) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 16)
        var carry: UInt8 = 0
        for i in stride(from: 15, through: 0, by: -1) {
            result[i] = block[i] << 1 | carry
            carry = block[i] >> 7
        }
        if carry != 0 { result[15] ^= 0x87 }
        return result
    }

    static func cmac(_ message: [UInt8], key: [UInt8]) throws -> [UInt8] {
        let l = try ecb([UInt8](repeating: 0, count: 16), key: key)
        let k1 = double(l), k2 = double(k1)
        let complete = !message.isEmpty && message.count % 16 == 0
        let blocks = max(1, (message.count + 15) / 16)
        var last = [UInt8](repeating: 0, count: 16)
        let tail = Array(message[((blocks - 1) * 16)...])
        if complete {
            for i in 0..<16 { last[i] = tail[i] ^ k1[i] }
        } else {
            var padded = tail + [0x80]
            padded += [UInt8](repeating: 0, count: 16 - padded.count)
            for i in 0..<16 { last[i] = padded[i] ^ k2[i] }
        }
        // CBC-MAC over the blocks: chaining by hand keeps one key schedule per call simple enough.
        var state = [UInt8](repeating: 0, count: 16)
        for block in 0..<(blocks - 1) {
            for i in 0..<16 { state[i] ^= message[block * 16 + i] }
            state = try ecb(state, key: key)
        }
        for i in 0..<16 { state[i] ^= last[i] }
        return try ecb(state, key: key)
    }

    // MARK: - SIV (RFC 5297)

    /// S2V over the associated data strings, then the plaintext.
    static func s2v(macKey: [UInt8], associatedData: [[UInt8]], plaintext: [UInt8]) throws -> [UInt8] {
        var d = try cmac([UInt8](repeating: 0, count: 16), key: macKey)
        for item in associatedData {
            let mac = try cmac(item, key: macKey)
            d = zip(double(d), mac).map { $0 ^ $1 }
        }
        var t: [UInt8]
        if plaintext.count >= 16 {
            // "xorend": the last 16 bytes of the plaintext absorb D.
            t = plaintext
            let offset = plaintext.count - 16
            for i in 0..<16 { t[offset + i] ^= d[i] }
        } else {
            var padded = plaintext + [0x80]
            padded += [UInt8](repeating: 0, count: 16 - padded.count)
            t = zip(double(d), padded).map { $0 ^ $1 }
        }
        return try cmac(t, key: macKey)
    }

    /// The synthetic IV as counter: bits 31 and 63 cleared, so the counter can be incremented as a 64-bit pair.
    private static func counter(from v: [UInt8]) -> [UInt8] {
        var q = v
        q[8] &= 0x7F; q[12] &= 0x7F
        return q
    }

    /// AES-SIV with two separate keys. Cryptomator passes its MAC masterkey as the S2V key (K1 in RFC 5297's
    /// notation, the first half of the combined key) and its encryption masterkey as the CTR key (K2).
    static func sivEncrypt(_ plaintext: [UInt8], ctrKey: [UInt8], macKey: [UInt8], associatedData: [[UInt8]] = []) throws -> [UInt8] {
        let v = try s2v(macKey: macKey, associatedData: associatedData, plaintext: plaintext)
        return v + (try ctr(plaintext, key: ctrKey, iv: counter(from: v)))
    }

    static func sivDecrypt(_ ciphertext: [UInt8], ctrKey: [UInt8], macKey: [UInt8], associatedData: [[UInt8]] = []) throws -> [UInt8] {
        guard ciphertext.count >= 16 else { throw Failure.malformed }
        let v = Array(ciphertext[0..<16])
        let plaintext = try ctr(Array(ciphertext[16...]), key: ctrKey, iv: counter(from: v))
        let expected = try s2v(macKey: macKey, associatedData: associatedData, plaintext: plaintext)
        guard constantTimeEqual(expected, v) else { throw Failure.unauthentic }
        return plaintext
    }

    // MARK: - Key wrap (RFC 3394)

    static let wrapIV: [UInt8] = [UInt8](repeating: 0xA6, count: 8)

    static func wrap(_ keyData: [UInt8], kek: [UInt8]) throws -> [UInt8] {
        guard keyData.count >= 16, keyData.count % 8 == 0 else { throw Failure.malformed }
        let n = keyData.count / 8
        var a = wrapIV
        var r = (0..<n).map { Array(keyData[($0 * 8)..<($0 * 8 + 8)]) }
        for j in 0...5 {
            for i in 0..<n {
                let b = try ecb(a + r[i], key: kek)
                a = Array(b[0..<8])
                let t = UInt64(n * j + i + 1)
                for k in 0..<8 { a[k] ^= UInt8(truncatingIfNeeded: t >> UInt64(8 * (7 - k))) }
                r[i] = Array(b[8..<16])
            }
        }
        return a + r.flatMap { $0 }
    }

    /// Throws `unauthentic` when the integrity check fails, which for a masterkey file means a wrong passphrase.
    static func unwrap(_ wrapped: [UInt8], kek: [UInt8]) throws -> [UInt8] {
        guard wrapped.count >= 24, wrapped.count % 8 == 0 else { throw Failure.malformed }
        let n = wrapped.count / 8 - 1
        var a = Array(wrapped[0..<8])
        var r = (0..<n).map { Array(wrapped[(8 + $0 * 8)..<(16 + $0 * 8)]) }
        for j in stride(from: 5, through: 0, by: -1) {
            for i in stride(from: n - 1, through: 0, by: -1) {
                let t = UInt64(n * j + i + 1)
                for k in 0..<8 { a[k] ^= UInt8(truncatingIfNeeded: t >> UInt64(8 * (7 - k))) }
                let b = try ecb(a + r[i], key: kek, encrypt: false)
                a = Array(b[0..<8])
                r[i] = Array(b[8..<16])
            }
        }
        guard constantTimeEqual(a, wrapIV) else { throw Failure.unauthentic }
        return r.flatMap { $0 }
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in 0..<a.count { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

/// The two text encodings of the vault format: Base32 for directory hashes, Base64url (padded) for names.
enum CryptomatorEncoding {
    private static let base32Alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".utf8)

    /// RFC 4648 Base32 with padding. A SHA-1 digest is exactly 32 characters and needs none.
    static func base32(_ data: [UInt8]) -> String {
        var output: [UInt8] = []
        var buffer = 0, bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte); bits += 8
            while bits >= 5 { output.append(base32Alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { output.append(base32Alphabet[(buffer << (5 - bits)) & 31]) }
        while output.count % 8 != 0 { output.append(UInt8(ascii: "=")) }
        return String(decoding: output, as: UTF8.self)
    }

    /// Base64url as Cryptomator writes it: the URL-safe alphabet, padding kept.
    static func base64url(_ data: [UInt8]) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    /// Reads Base64url with or without its padding. Returns nil for anything outside the alphabet.
    static func base64urlDecode(_ text: String) -> [UInt8]? {
        guard !text.contains("+"), !text.contains("/") else { return nil }
        var standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        if standard.count % 4 != 0 { standard += String(repeating: "=", count: 4 - standard.count % 4) }
        return Data(base64Encoded: standard).map { [UInt8]($0) }
    }
}
