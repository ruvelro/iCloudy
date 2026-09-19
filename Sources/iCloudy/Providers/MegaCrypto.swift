import Foundation
import CommonCrypto
import CryptoKit

/// Everything Mega encrypts on the client. Mega is end-to-end encrypted, so unlike every other provider here the
/// server never sees a file name: names, keys and contents are decrypted on this Mac with keys derived from the
/// password, and a mistake anywhere shows up as unreadable names rather than as an error.
enum MegaCrypto {
    // MARK: - Encoding

    /// Mega's base64: URL safe and unpadded. It appears in every field of every response.
    static func decode(_ text: String) -> Data {
        var padded = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        padded += String(repeating: "=", count: (4 - padded.count % 4) % 4)
        return Data(base64Encoded: padded) ?? Data()
    }
    static func encode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    /// Mega's multi-precision integers: a big-endian bit count, then that many bits of big-endian number.
    static func integers(_ data: Data, count: Int) -> [MegaBigInt] {
        var result: [MegaBigInt] = []
        var index = data.startIndex
        while result.count < count, index + 2 <= data.endIndex {
            let bits = Int(data[index]) << 8 | Int(data[index + 1])
            let bytes = (bits + 7) / 8
            guard index + 2 + bytes <= data.endIndex else { break }
            result.append(MegaBigInt(data[(index + 2)..<(index + 2 + bytes)]))
            index += 2 + bytes
        }
        return result
    }

    // MARK: - AES

    private static func crypt(_ data: Data, key: Data, iv: Data?, options: Int, encrypt: Bool) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    let run: (UnsafeRawPointer?) -> CCCryptorStatus = { ivBytes in
                        CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(options), keyBytes.baseAddress, key.count, ivBytes,
                                input.baseAddress, data.count, out.baseAddress, capacity, &moved)
                    }
                    return iv.map { $0.withUnsafeBytes { run($0.baseAddress) } } ?? run(nil)
                }
            }
        }
        guard status == kCCSuccess else { throw CloudError.message(L("Fallo al descifrar los datos de Mega.")) }
        return output.prefix(moved)
    }
    /// AES-128 in ECB with no padding. Mega uses it for keys, never for file contents.
    static func ecb(_ data: Data, key: Data, encrypt: Bool = false) throws -> Data {
        try crypt(data, key: key, iv: nil, options: kCCOptionECBMode, encrypt: encrypt)
    }
    /// AES-128 in CBC with no padding, which is how attributes travel.
    static func cbc(_ data: Data, key: Data, iv: Data = Data(count: 16), encrypt: Bool = false) throws -> Data {
        try crypt(data, key: key, iv: iv, options: 0, encrypt: encrypt)
    }
    /// AES-128 in counter mode, the cipher over file contents. The counter is the nonce followed by the block index,
    /// so any chunk can be decrypted on its own without replaying the ones before it.
    static func ctr(_ data: Data, key: Data, nonce: Data, blockOffset: UInt64) throws -> Data {
        var counter = nonce
        for shift in stride(from: 56, through: 0, by: -8) { counter.append(UInt8(truncatingIfNeeded: blockOffset >> UInt64(shift))) }
        var cryptor: CCCryptorRef?
        let created = counter.withUnsafeBytes { iv in
            key.withUnsafeBytes { keyBytes in
                CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
                                        CCPadding(ccNoPadding), iv.baseAddress, keyBytes.baseAddress, key.count,
                                        nil, 0, 0, CCModeOptions(kCCModeOptionCTR_BE), &cryptor)
            }
        }
        guard created == kCCSuccess, let cryptor else { throw CloudError.message(L("Fallo al descifrar los datos de Mega.")) }
        defer { CCCryptorRelease(cryptor) }
        var output = Data(count: data.count)
        var moved = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                CCCryptorUpdate(cryptor, input.baseAddress, data.count, out.baseAddress, capacity, &moved)
            }
        }
        guard status == kCCSuccess else { throw CloudError.message(L("Fallo al descifrar los datos de Mega.")) }
        return output.prefix(moved)
    }

    // MARK: - Keys

    /// A file key packs three things into 32 bytes: the AES key, the counter nonce and the expected content MAC.
    static func unpack(fileKey: Data) -> (key: Data, nonce: Data, mac: Data)? {
        guard fileKey.count >= 32 else { return nil }
        let bytes = [UInt8](fileKey)
        let key = Data((0..<16).map { bytes[$0] ^ bytes[$0 + 16] })
        return (key, Data(bytes[16..<24]), Data(bytes[24..<32]))
    }
    /// The 32-byte form that Mega stores, rebuilt from its parts.
    static func pack(key: Data, nonce: Data, mac: Data) -> Data {
        let tail = nonce + mac
        var packed = Data((0..<16).map { key[key.startIndex + $0] ^ tail[tail.startIndex + $0] })
        packed.append(tail)
        return packed
    }
    /// Key derivation for accounts created since 2018, and the only one Mega creates today.
    static func derive(password: String, salt: Data) throws -> (key: Data, hash: String) {
        var output = Data(count: 32)
        let status = output.withUnsafeMutableBytes { out -> Int32 in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), password, password.utf8.count,
                                     saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512), 100_000,
                                     out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
            }
        }
        guard status == kCCSuccess else { throw CloudError.message(L("Fallo al preparar la contraseña de Mega.")) }
        return (output.prefix(16), encode(output.suffix(16)))
    }
    /// Key derivation for accounts created before 2018. Slower and weaker, but still in use, so still supported.
    static func legacyKey(password: String) throws -> Data {
        var key = Data([0x93, 0xC4, 0x67, 0xE3, 0x7D, 0xB0, 0xC7, 0xA4, 0xD1, 0xBE, 0x3F, 0x81, 0x01, 0x52, 0xCB, 0x56])
        var padded = Data(password.utf8)
        padded.append(Data(count: (16 - padded.count % 16) % 16))
        let blocks = stride(from: 0, to: padded.count, by: 16).map { Data(padded[$0..<min($0 + 16, padded.count)]) }
        for _ in 0..<65_536 {
            for block in blocks { key = try ecb(key, key: block, encrypt: true) }
        }
        return key
    }
    /// The legacy proof of knowledge of the password, folded from the e-mail address.
    static func legacyHash(_ text: String, key: Data) throws -> String {
        var padded = Data(text.utf8)
        padded.append(Data(count: (16 - padded.count % 16) % 16))
        var folded = [UInt8](repeating: 0, count: 16)
        for (index, byte) in padded.enumerated() { folded[index % 16] ^= byte }
        var hash = Data(folded)
        for _ in 0..<16_384 { hash = try ecb(hash, key: key, encrypt: true) }
        return encode(hash.prefix(4) + hash[(hash.startIndex + 8)..<(hash.startIndex + 12)])
    }

    // MARK: - Attributes

    /// File and folder names travel encrypted, prefixed with "MEGA" so a wrong key is obvious instead of silent.
    static func attributes(_ data: Data, key: Data) -> [String: Any]? {
        guard data.count >= 16, let plain = try? cbc(data, key: key) else { return nil }
        guard plain.starts(with: Data("MEGA".utf8)) else { return nil }
        var json = plain.dropFirst(4)
        while json.last == 0 { json = json.dropLast() }
        return (try? JSONSerialization.jsonObject(with: Data(json))) as? [String: Any]
    }
    static func encodeAttributes(_ values: [String: Any], key: Data) throws -> Data {
        var plain = Data("MEGA".utf8)
        plain.append(try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]))
        plain.append(Data(count: (16 - plain.count % 16) % 16))
        return try cbc(plain, key: key, encrypt: true)
    }

    // MARK: - Content integrity

    /// Mega splits a file into growing chunks: 128 KiB, then 256 KiB and so on up to 1 MiB, then 1 MiB each.
    /// Both the counter blocks and the content MAC are defined over exactly these boundaries.
    static func chunks(of size: Int64) -> [(offset: Int64, length: Int64)] {
        guard size > 0 else { return [] }
        var result: [(Int64, Int64)] = []
        var offset: Int64 = 0
        var length: Int64 = 131_072
        while offset + length < size {
            result.append((offset, length))
            offset += length
            if length < 1_048_576 { length += 131_072 }
        }
        result.append((offset, size - offset))
        return result
    }
    /// CBC-MAC of one chunk, seeded with the nonce twice over.
    static func chunkMAC(_ data: Data, key: Data, nonce: Data) throws -> Data {
        var mac = nonce + nonce
        var index = data.startIndex
        while index < data.endIndex {
            let end = min(index + 16, data.endIndex)
            var block = Data(data[index..<end])
            block.append(Data(count: 16 - block.count))
            mac = try ecb(Data(zip(mac, block).map { $0 ^ $1 }), key: key, encrypt: true)
            index = end
        }
        return mac
    }
    /// Folds every chunk's MAC into the 8 bytes stored inside the file key, which is what proves a download intact.
    static func metaMAC(chunks macs: [Data], key: Data) throws -> Data {
        var file = Data(count: 16)
        for mac in macs { file = try ecb(Data(zip(file, mac).map { $0 ^ $1 }), key: key, encrypt: true) }
        let bytes = [UInt8](file)
        return Data((0..<4).map { bytes[$0] ^ bytes[$0 + 4] } + (0..<4).map { bytes[$0 + 8] ^ bytes[$0 + 12] })
    }
    // MARK: - Proof of work

    /// Mega answers some requests with HTTP 402 and a challenge instead of a result, and only accepts the request
    /// once the client has spent a measurable amount of work on it. It is an anti-abuse measure, not a payment: the
    /// server picks how hard, the client searches for a four-byte prefix whose hash falls under a threshold.
    ///
    /// The layout is Mega's and has to match exactly: the prefix, then the 48-byte token repeated 262144 times, all
    /// of it hashed with SHA-256 on every attempt.
    static func hashcash(token: String, easiness: Int) throws -> String {
        let seed = decode(token)
        guard seed.count == 48 else { throw CloudError.message(L("Mega envió un desafío que no se entiende.")) }
        let threshold = Self.threshold(easiness: easiness)
        var buffer = [UInt8](repeating: 0, count: 4 + 262_144 * 48)
        seed.withUnsafeBytes { raw in
            buffer.withUnsafeMutableBufferPointer { out in
                guard let source = raw.bindMemory(to: UInt8.self).baseAddress, let start = out.baseAddress else { return }
                for index in 0..<262_144 { (start + 4 + index * 48).update(from: source, count: 48) }
            }
        }
        // The prefix is a counter over the first four bytes. The bound is far beyond what any easiness needs, and
        // exists so a change on Mega's side cannot turn this into an endless loop.
        for _ in 0..<(1 << 22) {
            try Task.checkCancellation()
            var index = 0
            while true {
                buffer[index] &+= 1
                if buffer[index] != 0 { break }
                index += 1
            }
            let digest = SHA256.hash(data: buffer)
            let head = digest.withUnsafeBytes { raw -> UInt32 in
                let bytes = raw.bindMemory(to: UInt8.self)
                return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
            }
            if head <= threshold { return encode(Data(buffer[0..<4])) }
        }
        throw CloudError.message(L("No se pudo resolver el desafío de Mega."))
    }
    /// How large the first four bytes of the hash may be. The higher the easiness, the larger the threshold and the
    /// fewer attempts it takes.
    static func threshold(easiness: Int) -> UInt32 {
        UInt32(truncatingIfNeeded: (((easiness & 63) << 1) + 1) << ((easiness >> 6) * 7 + 3))
    }

    static func randomKey(count: Int = 32) -> Data {
        var bytes = Data(count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return bytes
    }
}
