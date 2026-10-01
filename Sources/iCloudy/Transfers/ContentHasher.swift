import Foundation
import CryptoKit

/// One streaming digest in whichever algorithm the provider lists. Only the one asked for is computed.
struct ContentHasher {
    let algorithm: ContentHash.Algorithm
    private var md5: Insecure.MD5?
    private var sha1: Insecure.SHA1?
    private var sha256: SHA256?
    private var quickXor: QuickXorHash?
    private var dropbox: DropboxContentHash?
    init(_ algorithm: ContentHash.Algorithm) {
        self.algorithm = algorithm
        switch algorithm {
        case .md5: md5 = Insecure.MD5()
        case .sha1: sha1 = Insecure.SHA1()
        case .sha256: sha256 = SHA256()
        case .quickXor: quickXor = QuickXorHash()
        case .dropbox: dropbox = DropboxContentHash()
        }
    }
    mutating func update(_ data: Data) {
        md5?.update(data: data); sha1?.update(data: data); sha256?.update(data: data)
        quickXor?.update(data); dropbox?.update(data)
    }
    /// Lowercase hexadecimal, or Base64 for QuickXorHash, which is how Graph spells it.
    func finalize() -> String {
        if let md5 { return UploadHasher.hex(md5.finalize()) }
        if let sha1 { return UploadHasher.hex(sha1.finalize()) }
        if let sha256 { return UploadHasher.hex(sha256.finalize()) }
        if let quickXor { return quickXor.finalize().base64EncodedString() }
        return dropbox?.finalize() ?? ""
    }
    /// Reads the file once, in Dropbox-sized blocks so its block hash never has to buffer, and never holds more than
    /// one block in memory. Returns the digest and the number of bytes it covered.
    nonisolated static func digest(of url: URL, algorithm: ContentHash.Algorithm) throws -> (digest: String, bytes: Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = ContentHasher(algorithm)
        var bytes: Int64 = 0
        while true {
            try Task.checkCancellation()
            let chunk = try autoreleasepool { try handle.read(upToCount: Int(DropboxProvider.dropboxChunk)) ?? Data() }
            if chunk.isEmpty { break }
            hasher.update(chunk)
            bytes += Int64(chunk.count)
        }
        return (hasher.finalize(), bytes)
    }
}

/// Microsoft's QuickXorHash: every byte is XORed into a 160-bit circular register, each one 11 bits further along
/// than the last, and the total length is XORed into the top 64 bits at the end. Graph lists it as Base64.
struct QuickXorHash {
    private static let width = 160
    private static let shift = 11
    /// The register as 20 little-endian bytes, folded 8 at a time.
    private var cells = [UInt64](repeating: 0, count: 3)
    /// Bit position of the next byte's lowest bit.
    private var offset = 0
    private var length: Int64 = 0

    mutating func update(_ data: Data) {
        guard !data.isEmpty else { return }
        // Bytes 160 apart land on the same bit (11 × 160 is a whole number of turns), so they are XORed together
        // first, eight lanes at a time. Only the 160 folded bytes then need placing in the register.
        var lanes = [UInt64](repeating: 0, count: Self.width / 8)
        var tail = [UInt8](repeating: 0, count: Self.width)
        data.withUnsafeBytes { raw in
            let count = raw.count
            var start = 0
            while start + Self.width <= count {
                for lane in 0..<lanes.count { lanes[lane] ^= raw.loadUnaligned(fromByteOffset: start + lane * 8, as: UInt64.self) }
                start += Self.width
            }
            for index in start..<count { tail[index - start] ^= raw[index] }
        }
        for index in 0..<min(data.count, Self.width) {
            let byte = UInt8(truncatingIfNeeded: UInt64(littleEndian: lanes[index / 8]) >> (UInt64(index % 8) * 8)) ^ tail[index]
            place(byte, at: (offset + index * Self.shift) % Self.width)
        }
        offset = (offset + Self.shift * (data.count % Self.width)) % Self.width
        length += Int64(data.count)
    }
    /// XORs one byte into the register at `bit`, wrapping past bit 159 back to bit 0. The last cell holds 32 bits.
    private mutating func place(_ byte: UInt8, at bit: Int) {
        let value = UInt64(byte), cell = bit / 64, within = bit % 64
        let bits = cell == cells.count - 1 ? Self.width - 64 * (cells.count - 1) : 64
        let mask: UInt64 = bits == 64 ? .max : (1 << UInt64(bits)) - 1
        cells[cell] ^= (value << UInt64(within)) & mask
        if within + 8 > bits { cells[cell == cells.count - 1 ? 0 : cell + 1] ^= value >> UInt64(bits - within) }
    }
    func finalize() -> Data {
        var bytes = [UInt8](repeating: 0, count: Self.width / 8)
        for index in bytes.indices { bytes[index] = UInt8(truncatingIfNeeded: cells[index / 8] >> (UInt64(index % 8) * 8)) }
        // The length, little-endian, goes over the last eight bytes.
        for index in 0..<8 { bytes[bytes.count - 8 + index] ^= UInt8(truncatingIfNeeded: UInt64(bitPattern: length) >> (UInt64(index) * 8)) }
        return Data(bytes)
    }
}
