import XCTest
import CryptoKit
@testable import iCloudy

/// The digests downloads are checked with, and the listings that carry the provider's side of the comparison.
@MainActor
final class ContentHashTests: XCTestCase {
    private func destination() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testQuickXorHashMatchesPublishedVectors() {
        let vectors = [("", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="), ("Sg==", "SgAAAAAAAAAAAAAAAQAAAAAAAAA="),
                       ("tbQ=", "taAFAAAAAAAAAAAAAgAAAAAAAAA="), ("0pZP", "0rDEEwAAAAAAAAAAAwAAAAAAAAA=")]
        for (input, expected) in vectors {
            var hash = QuickXorHash(); hash.update(Data(base64Encoded: input)!)
            XCTAssertEqual(hash.finalize().base64EncodedString(), expected, input)
        }
    }

    func testQuickXorHashAgreesWithTheBitByBitDefinitionWhateverTheChunking() {
        // The published vectors are too short to wrap around the 160-bit register; this reference does it one bit
        // at a time, exactly as the algorithm is described, and the real one has to agree at every length.
        var generator = SystemRandomNumberGenerator()
        for length in [1, 15, 21, 159, 160, 161, 319, 1000, 4099] {
            let bytes = (0..<length).map { _ in UInt8.random(in: 0...255, using: &generator) }
            var whole = QuickXorHash(); whole.update(Data(bytes))
            XCTAssertEqual(whole.finalize(), Self.referenceQuickXor(bytes), "\(length) bytes")
            for chunk in [1, 7, 160, 333] {
                var pieces = QuickXorHash()
                for start in stride(from: 0, to: length, by: chunk) { pieces.update(Data(bytes[start..<min(length, start + chunk)])) }
                XCTAssertEqual(pieces.finalize(), whole.finalize(), "\(length) bytes in chunks of \(chunk)")
            }
        }
    }

    func testStreamingDigestsMatchTheOneShotOnes() throws {
        // Larger than one Dropbox block, so the block hash and the chunked read both cross a boundary.
        let payload = Data((0..<(5 * 1024 * 1024 + 17)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let url = destination(); try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try ContentHasher.digest(of: url, algorithm: .md5).digest, UploadHasher.hex(Insecure.MD5.hash(data: payload)))
        XCTAssertEqual(try ContentHasher.digest(of: url, algorithm: .sha1).digest, UploadHasher.hex(Insecure.SHA1.hash(data: payload)))
        XCTAssertEqual(try ContentHasher.digest(of: url, algorithm: .sha256).bytes, Int64(payload.count))
        let block = 4 * 1024 * 1024
        let blocks = Data(SHA256.hash(data: payload.prefix(block))) + Data(SHA256.hash(data: payload.dropFirst(block)))
        XCTAssertEqual(try ContentHasher.digest(of: url, algorithm: .dropbox).digest, UploadHasher.hex(SHA256.hash(data: blocks)))
        var quick = QuickXorHash(); quick.update(payload)
        XCTAssertEqual(try ContentHasher.digest(of: url, algorithm: .quickXor).digest, quick.finalize().base64EncodedString())
        XCTAssertTrue(ContentHash(algorithm: .sha1, value: "ABCDEF").matches("abcdef"), "Graph spells its hex in capitals")
    }

    func testListingsCarryEachProvidersChecksum() {
        XCTAssertEqual(GoogleDriveProvider.googleFile(["id": "a", "name": "a.bin", "md5Checksum": "abc"])?.checksum, ContentHash(algorithm: .md5, value: "abc"))
        XCTAssertNil(GoogleDriveProvider.googleFile(["id": "d", "name": "Doc", "mimeType": "application/vnd.google-apps.document"])?.checksum)
        let hashes: [String: Any] = ["quickXorHash": "qx", "sha1Hash": "S1", "sha256Hash": "S256"]
        XCTAssertEqual(OneDriveProvider.microsoftFile(["id": "m", "name": "m.bin", "file": ["hashes": hashes]])?.checksum,
                       ContentHash(algorithm: .quickXor, value: "qx"), "QuickXorHash is the one every account type has")
        XCTAssertEqual(OneDriveProvider.microsoftFile(["id": "m", "name": "m.bin", "file": ["hashes": ["sha1Hash": "S1"]]])?.checksum,
                       ContentHash(algorithm: .sha1, value: "S1"))
        XCTAssertEqual(DropboxProvider.dropboxFile([".tag": "file", "name": "x", "path_lower": "/x", "content_hash": "dh"])?.checksum,
                       ContentHash(algorithm: .dropbox, value: "dh"))
        XCTAssertEqual(BoxProvider.boxFile(["id": "1", "name": "x", "type": "file", "sha1": "b1"])?.checksum, ContentHash(algorithm: .sha1, value: "b1"))
        XCTAssertNil(BoxProvider.boxFile(["id": "2", "name": "y", "type": "file", "sha1": ""])?.checksum)
    }

    func testAChecksumWrittenByANewerVersionDoesNotBreakTheSavedQueue() throws {
        let json = #"{"id":"a","name":"a","mime":"text/plain","isFolder":false,"checksum":{"algorithm":"blake3","value":"x"}}"#
        let file = try JSONDecoder().decode(CloudFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.id, "a"); XCTAssertNil(file.checksum)
        let legacy = #"{"id":"b","name":"b","mime":"text/plain","isFolder":false}"#
        XCTAssertNil(try JSONDecoder().decode(CloudFile.self, from: Data(legacy.utf8)).checksum)
    }

    /// QuickXorHash as Microsoft describes it: each byte rotated 11 bits further into a 160-bit register, one bit at a time.
    private static func referenceQuickXor(_ bytes: [UInt8]) -> Data {
        var bits = [Bool](repeating: false, count: 160)
        for (index, byte) in bytes.enumerated() {
            let start = (index * 11) % 160
            for bit in 0..<8 where (byte >> bit) & 1 == 1 { bits[(start + bit) % 160].toggle() }
        }
        var out = [UInt8](repeating: 0, count: 20)
        for bit in 0..<160 where bits[bit] { out[bit / 8] |= 1 << (bit % 8) }
        let length = UInt64(bytes.count)
        for index in 0..<8 { out[12 + index] ^= UInt8(truncatingIfNeeded: length >> (8 * UInt64(index))) }
        return Data(out)
    }
}
