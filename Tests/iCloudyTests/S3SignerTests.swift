import XCTest
@testable import iCloudy

/// SigV4 replayed against the published examples: the generic test suite AWS ships for every service, and the worked
/// examples of the S3 documentation, which add S3's own rules (single encoding, the payload hash header, presigning).
/// A signature that matches these cannot match by accident.
final class S3SignerTests: XCTestCase {
    private static func date(_ stamp: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.date(from: stamp)!
    }
    /// The key of the S3 documentation examples.
    private let docKeys = S3Keys(accessKey: "AKIAIOSFODNN7EXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    /// The key of the generic SigV4 test suite.
    private let suiteKeys = S3Keys(accessKey: "AKIDEXAMPLE", secretKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

    func testSigningKeyDerivationMatchesTheDocumentation() {
        let key = S3Signer.signingKey(secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", day: "20120215", region: "us-east-1", service: "iam")
        XCTAssertEqual(S3Signer.hex(key), "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    func testGenericSuiteGetVanilla() {
        let date = Self.date("20150830T123600Z")
        let url = URL(string: "https://example.amazonaws.com/")!
        let header = S3Signer.authorization(method: "GET", url: url, headers: ["X-Amz-Date": "20150830T123600Z"],
                                            payloadHash: S3Signer.emptyPayloadHash, keys: suiteKeys, region: "us-east-1",
                                            service: "service", date: date)
        XCTAssertEqual(header, "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
    }

    func testGenericSuiteSortsTheQueryByName() {
        let date = Self.date("20150830T123600Z")
        let url = URL(string: "https://example.amazonaws.com/?Param2=value2&Param1=value1")!
        XCTAssertEqual(S3Signer.canonicalQuery(url), "Param1=value1&Param2=value2")
        let header = S3Signer.authorization(method: "GET", url: url, headers: ["X-Amz-Date": "20150830T123600Z"],
                                            payloadHash: S3Signer.emptyPayloadHash, keys: suiteKeys, region: "us-east-1",
                                            service: "service", date: date)
        XCTAssertTrue(header.hasSuffix("Signature=b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500"), header)
    }

    func testS3DocumentationGetObjectWithRange() {
        let date = Self.date("20130524T000000Z")
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!
        let headers = ["Range": "bytes=0-9", "x-amz-content-sha256": S3Signer.emptyPayloadHash, "x-amz-date": "20130524T000000Z"]
        let (canonical, _) = S3Signer.canonicalRequest(method: "GET", url: url, headers: headers, payloadHash: S3Signer.emptyPayloadHash)
        XCTAssertEqual(canonical, """
        GET
        /test.txt

        host:examplebucket.s3.amazonaws.com
        range:bytes=0-9
        x-amz-content-sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        x-amz-date:20130524T000000Z

        host;range;x-amz-content-sha256;x-amz-date
        e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
        """)
        let header = S3Signer.authorization(method: "GET", url: url, headers: headers, payloadHash: S3Signer.emptyPayloadHash,
                                            keys: docKeys, region: "us-east-1", date: date)
        XCTAssertEqual(header, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    func testS3DocumentationPutObjectEncodesTheKeyOnce() {
        let date = Self.date("20130524T000000Z")
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/test$file.text")!
        XCTAssertEqual(S3Signer.canonicalURI(url), "/test%24file.text")
        let payload = S3Signer.sha256Hex(Data("Welcome to Amazon S3.".utf8))
        XCTAssertEqual(payload, "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072")
        let headers = ["Date": "Fri, 24 May 2013 00:00:00 GMT", "x-amz-date": "20130524T000000Z",
                       "x-amz-storage-class": "REDUCED_REDUNDANCY", "x-amz-content-sha256": payload]
        let header = S3Signer.authorization(method: "PUT", url: url, headers: headers, payloadHash: payload,
                                            keys: docKeys, region: "us-east-1", date: date)
        XCTAssertTrue(header.contains("SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class,"), header)
        XCTAssertTrue(header.hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"), header)
    }

    func testS3DocumentationSubresourceWithoutValue() {
        let date = Self.date("20130524T000000Z")
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/?lifecycle")!
        XCTAssertEqual(S3Signer.canonicalQuery(url), "lifecycle=")
        let headers = ["x-amz-date": "20130524T000000Z", "x-amz-content-sha256": S3Signer.emptyPayloadHash]
        let header = S3Signer.authorization(method: "GET", url: url, headers: headers, payloadHash: S3Signer.emptyPayloadHash,
                                            keys: docKeys, region: "us-east-1", date: date)
        XCTAssertTrue(header.hasSuffix("Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"), header)
    }

    func testS3DocumentationListObjects() {
        let date = Self.date("20130524T000000Z")
        let url = URL(string: "https://examplebucket.s3.amazonaws.com/?max-keys=2&prefix=J")!
        let headers = ["x-amz-date": "20130524T000000Z", "x-amz-content-sha256": S3Signer.emptyPayloadHash]
        let header = S3Signer.authorization(method: "GET", url: url, headers: headers, payloadHash: S3Signer.emptyPayloadHash,
                                            keys: docKeys, region: "us-east-1", date: date)
        XCTAssertTrue(header.hasSuffix("Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"), header)
    }

    func testS3DocumentationPresignedURL() throws {
        let date = Self.date("20130524T000000Z")
        let url = try XCTUnwrap(S3Signer.presign(url: URL(string: "https://examplebucket.s3.amazonaws.com/test.txt")!,
                                                 keys: docKeys, region: "us-east-1", date: date, expires: 86400))
        XCTAssertEqual(url.absoluteString, "https://examplebucket.s3.amazonaws.com/test.txt?X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request&X-Amz-Date=20130524T000000Z&X-Amz-Expires=86400&X-Amz-SignedHeaders=host&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404")
    }

    func testPresignedLinksNeverOutliveAWeek() throws {
        let url = try XCTUnwrap(S3Signer.presign(url: URL(string: "https://b.s3.amazonaws.com/k")!, keys: docKeys,
                                                 region: "us-east-1", date: Date(), expires: 30 * 86400))
        let expires = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "X-Amz-Expires" }?.value
        XCTAssertEqual(expires, "604800")
    }

    func testEncodingFollowsS3Rules() {
        XCTAssertEqual(S3Signer.encode("a b+c/ñ~*"), "a%20b%2Bc%2F%C3%B1~%2A")
        XCTAssertEqual(S3Signer.encode("fotos/2024/a b.jpg", slash: true), "fotos/2024/a%20b.jpg")
        // Header values are trimmed and inner runs of spaces folded before signing.
        let (canonical, signed) = S3Signer.canonicalHeaders(URL(string: "http://minio.local:9000/b")!, headers: ["X-Amz-Meta-Nota": "  a   b  "])
        XCTAssertEqual(canonical, "host:minio.local:9000\nx-amz-meta-nota:a b\n")
        XCTAssertEqual(signed, "host;x-amz-meta-nota")
    }
}
