import Foundation
import CryptoKit
import CommonCrypto

/// Names, directory ids and file contents of a Cryptomator vault (format 8). Pure functions of the masterkey: no
/// I/O beyond the two files a content operation reads and writes, so everything here is tested against the
/// published vectors without a provider in sight.
struct CryptomatorCryptor: Sendable {
    let masterkey: CryptomatorMasterkey
    let combo: CryptomatorCipherCombo
    /// Where nonces and content keys come from. Tests replace it to reproduce the published vectors byte for byte.
    var random: @Sendable (Int) throws -> [UInt8] = { try CryptomatorRandom.bytes($0) }

    init(masterkey: CryptomatorMasterkey, combo: CryptomatorCipherCombo = .sivGCM) {
        self.masterkey = masterkey; self.combo = combo
    }

    static let cleartextChunkSize = 32 * 1024
    var nonceSize: Int { combo == .sivGCM ? 12 : 16 }
    var tagSize: Int { combo == .sivGCM ? 16 : 32 }
    /// 68 bytes for GCM: nonce, 40 encrypted bytes (eight reserved 0xFF and the content key) and the tag.
    var headerSize: Int { nonceSize + 8 + 32 + tagSize }
    var chunkOverhead: Int { nonceSize + tagSize }
    var ciphertextChunkSize: Int { Self.cleartextChunkSize + chunkOverhead }

    // MARK: - Directories and names

    /// base32(sha1(aesSiv(dirId))) — the directory's storage name under `d/`, split as two characters and thirty.
    func hashDirectoryID(_ dirID: String) throws -> String {
        let encrypted = try AESModes.sivEncrypt(Array(dirID.utf8), ctrKey: masterkey.encryptionKey, macKey: masterkey.macKey)
        return CryptomatorEncoding.base32(Array(Insecure.SHA1.hash(data: encrypted)))
    }

    func directoryPath(_ dirID: String) throws -> (shard: String, name: String) {
        let hash = try hashDirectoryID(dirID)
        return (String(hash.prefix(2)), String(hash.dropFirst(2)))
    }

    /// The encrypted name without extension: base64url(aesSiv(NFC name, parent dirId as associated data)).
    func encryptName(_ name: String, parentDirID: String) throws -> String {
        let cleartext = Array(name.precomposedStringWithCanonicalMapping.utf8)
        let encrypted = try AESModes.sivEncrypt(cleartext, ctrKey: masterkey.encryptionKey, macKey: masterkey.macKey,
                                                associatedData: [Array(parentDirID.utf8)])
        return CryptomatorEncoding.base64url(encrypted)
    }

    func decryptName(_ encrypted: String, parentDirID: String) throws -> String {
        guard let bytes = CryptomatorEncoding.base64urlDecode(encrypted), bytes.count >= 16 else { throw AESModes.Failure.malformed }
        let cleartext = try AESModes.sivDecrypt(bytes, ctrKey: masterkey.encryptionKey, macKey: masterkey.macKey,
                                                associatedData: [Array(parentDirID.utf8)])
        guard let name = String(bytes: cleartext, encoding: .utf8), !name.isEmpty else { throw AESModes.Failure.malformed }
        return name
    }

    /// The name of the node as stored: `<encrypted>.c9r`, or `<base64url(sha1(that))>.c9s` once it passes the threshold.
    /// `full` is always the `.c9r` form, which is what a shortened node keeps in its `name.c9s`.
    func nodeName(_ name: String, parentDirID: String, threshold: Int) throws -> (node: String, full: String) {
        let full = try encryptName(name, parentDirID: parentDirID) + ".c9r"
        return (full.count > threshold ? Self.deflate(full) : full, full)
    }

    static func deflate(_ fullName: String) -> String {
        CryptomatorEncoding.base64url(Array(Insecure.SHA1.hash(data: Array(fullName.utf8)))) + ".c9s"
    }

    // MARK: - Sizes

    /// Bytes a cleartext of this size takes once encrypted, header included. An empty file is the header alone.
    func ciphertextSize(cleartext size: Int64) -> Int64 {
        let chunk = Int64(Self.cleartextChunkSize)
        let full = size / chunk, rest = size % chunk
        return Int64(headerSize) + full * Int64(ciphertextChunkSize) + (rest == 0 ? 0 : rest + Int64(chunkOverhead))
    }

    /// The cleartext size of a ciphertext, or nil when no ciphertext can have this size. A trailing chunk with an empty
    /// payload is accepted: Cryptomator's own writer leaves one behind in some files.
    func cleartextSize(ciphertext size: Int64) -> Int64? {
        let payload = size - Int64(headerSize)
        guard payload >= 0 else { return nil }
        let full = payload / Int64(ciphertextChunkSize), rest = payload % Int64(ciphertextChunkSize)
        guard rest == 0 || rest >= Int64(chunkOverhead) else { return nil }
        return full * Int64(Self.cleartextChunkSize) + (rest == 0 ? 0 : rest - Int64(chunkOverhead))
    }

    // MARK: - Header and chunks

    struct Header: Equatable { let nonce: [UInt8]; let contentKey: [UInt8] }

    func newHeader() throws -> Header { Header(nonce: try random(nonceSize), contentKey: try random(32)) }

    func encryptHeader(_ header: Header) throws -> [UInt8] {
        let payload = [UInt8](repeating: 0xFF, count: 8) + header.contentKey
        switch combo {
        case .sivGCM:
            return try gcmSeal(payload, key: masterkey.encryptionKey, nonce: header.nonce, aad: [])
        case .sivCTRMAC:
            let ciphertext = try AESModes.ctr(payload, key: masterkey.encryptionKey, iv: header.nonce)
            return header.nonce + ciphertext + hmac(header.nonce + ciphertext)
        }
    }

    func decryptHeader(_ bytes: [UInt8]) throws -> Header {
        guard bytes.count == headerSize else { throw AESModes.Failure.malformed }
        let nonce = Array(bytes[0..<nonceSize])
        let payload: [UInt8]
        switch combo {
        case .sivGCM:
            payload = try gcmOpen(bytes, key: masterkey.encryptionKey, aad: [])
        case .sivCTRMAC:
            let ciphertext = Array(bytes[nonceSize..<(headerSize - tagSize)])
            guard AESModes.constantTimeEqual(hmac(nonce + ciphertext), Array(bytes[(headerSize - tagSize)...])) else { throw AESModes.Failure.unauthentic }
            payload = try AESModes.ctr(ciphertext, key: masterkey.encryptionKey, iv: nonce)
        }
        return Header(nonce: nonce, contentKey: Array(payload[8...]))
    }

    /// Chunk number (64-bit big-endian) and header nonce bind every chunk to its place and to its file.
    private func chunkAAD(_ number: UInt64, header: Header) -> [UInt8] {
        let counter = withUnsafeBytes(of: number.bigEndian, Array.init)
        return combo == .sivGCM ? counter + header.nonce : header.nonce + counter
    }

    func encryptChunk(_ cleartext: [UInt8], number: UInt64, header: Header, nonce suppliedNonce: [UInt8]? = nil) throws -> [UInt8] {
        let nonce = try suppliedNonce ?? random(nonceSize)
        switch combo {
        case .sivGCM:
            return try gcmSeal(cleartext, key: header.contentKey, nonce: nonce, aad: chunkAAD(number, header: header))
        case .sivCTRMAC:
            let ciphertext = try AESModes.ctr(cleartext, key: header.contentKey, iv: nonce)
            return nonce + ciphertext + hmac(chunkAAD(number, header: header) + nonce + ciphertext)
        }
    }

    func decryptChunk(_ bytes: [UInt8], number: UInt64, header: Header) throws -> [UInt8] {
        guard bytes.count >= chunkOverhead else { throw AESModes.Failure.malformed }
        switch combo {
        case .sivGCM:
            return try gcmOpen(bytes, key: header.contentKey, aad: chunkAAD(number, header: header))
        case .sivCTRMAC:
            let nonce = Array(bytes[0..<nonceSize]), ciphertext = Array(bytes[nonceSize..<(bytes.count - tagSize)])
            let expected = hmac(chunkAAD(number, header: header) + nonce + ciphertext)
            guard AESModes.constantTimeEqual(expected, Array(bytes[(bytes.count - tagSize)...])) else { throw AESModes.Failure.unauthentic }
            return try AESModes.ctr(ciphertext, key: header.contentKey, iv: nonce)
        }
    }

    private func gcmSeal(_ plaintext: [UInt8], key: [UInt8], nonce: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: AES.GCM.Nonce(data: nonce), authenticating: aad)
        return nonce + Array(box.ciphertext) + Array(box.tag)
    }

    private func gcmOpen(_ bytes: [UInt8], key: [UInt8], aad: [UInt8]) throws -> [UInt8] {
        do {
            let box = try AES.GCM.SealedBox(combined: bytes)
            return Array(try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad))
        } catch { throw AESModes.Failure.unauthentic }
    }

    private func hmac(_ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: masterkey.macKey)))
    }

    // MARK: - Whole contents

    /// Small payloads such as `dirid.c9r`, in memory.
    func encrypt(_ data: [UInt8]) throws -> [UInt8] {
        let header = try newHeader()
        var output = try encryptHeader(header)
        var number: UInt64 = 0
        var offset = 0
        while offset < data.count {
            let end = min(offset + Self.cleartextChunkSize, data.count)
            output += try encryptChunk(Array(data[offset..<end]), number: number, header: header)
            offset = end; number += 1
        }
        return output
    }

    func decrypt(_ data: [UInt8]) throws -> [UInt8] {
        guard data.count >= headerSize else { throw AESModes.Failure.malformed }
        let header = try decryptHeader(Array(data[0..<headerSize]))
        var output: [UInt8] = []
        var offset = headerSize, number: UInt64 = 0
        while offset < data.count {
            let end = min(offset + ciphertextChunkSize, data.count)
            output += try decryptChunk(Array(data[offset..<end]), number: number, header: header)
            offset = end; number += 1
        }
        return output
    }

    /// Encrypts a file into another, one 32 KiB chunk at a time: memory use does not depend on the file's size.
    func encryptFile(from source: URL, to destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        let header = try newHeader()
        try output.write(contentsOf: encryptHeader(header))
        var number: UInt64 = 0, done: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try input.read(upToCount: Self.cleartextChunkSize) } ?? Data()
            if chunk.isEmpty { break }
            try output.write(contentsOf: encryptChunk([UInt8](chunk), number: number, header: header))
            number += 1; done += Int64(chunk.count)
            progress?(done)
        }
    }

    /// Decrypts a file into another, chunk by chunk. Any chunk that fails authentication stops the work and removes
    /// what was written: a partly decrypted file is not left behind looking complete.
    func decryptFile(from source: URL, to destination: URL, progress: ((Int64) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            guard let headerBytes = try input.read(upToCount: headerSize), headerBytes.count == headerSize else { throw AESModes.Failure.malformed }
            let header = try decryptHeader([UInt8](headerBytes))
            var number: UInt64 = 0, done: Int64 = 0
            while true {
                try Task.checkCancellation()
                let chunk = try autoreleasepool { try input.read(upToCount: ciphertextChunkSize) } ?? Data()
                if chunk.isEmpty { break }
                let cleartext = try decryptChunk([UInt8](chunk), number: number, header: header)
                try output.write(contentsOf: cleartext)
                number += 1; done += Int64(cleartext.count)
                progress?(done)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }
}
