import XCTest
@testable import iCloudy

/// Counts what reaches the network and answers every request with a 404.
private final class CountingProtocol: URLProtocol {
    nonisolated(unsafe) static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: [:])!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The capability table says what each provider does; the providers do it. These check that the two agree where
/// nothing else ties them.
@MainActor
final class CapabilityTableTests: XCTestCase {
    func testTheThumbnailFlagMatchesTheProvidersThatDrawThem() async throws {
        let picture = CloudFile(id: "123", name: "foto.jpg", mime: "image/jpeg", size: 10, modified: nil, webURL: nil, isFolder: false)
        for cloud in Cloud.allCases where cloud != .volume {
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [CountingProtocol.self]
            let account = Account(id: "\(cloud.rawValue):test", cloud: cloud, name: "t", email: "t@example.com", clientID: "client",
                                  clientSecret: nil, serverURL: "https://server.example.com/")
            let api = CloudAPI(account: account, session: URLSession(configuration: config), tokenProvider: { "token" })
            CountingProtocol.requests = 0
            // A provider without thumbnails answers nil without asking anybody; one with them asks its server.
            let answer = try? await api.thumbnail(of: picture, side: 128)
            let asked = CountingProtocol.requests > 0
            XCTAssertEqual(asked, cloud.capabilities.thumbnails,
                           "\(cloud): la tabla dice \(cloud.capabilities.thumbnails) y el proveedor \(asked ? "pide" : "no pide") miniaturas")
            if !cloud.capabilities.thumbnails { XCTAssertNil(answer ?? nil) }
        }
        // Volumes draw them on this Mac with Quick Look, without any request.
        XCTAssertTrue(Cloud.volume.capabilities.thumbnails)
    }

    func testFactsThatUsedToLiveOutsideTheTable() {
        XCTAssertEqual(Cloud.allCases.filter { $0.capabilities.signIn == .web }, [.o2])
        XCTAssertEqual(Set(Cloud.allCases.filter(\.needsKeepAlive)), [.o2])
        XCTAssertEqual(Set(Cloud.allCases.filter(\.isExperimental)), [.mega, .o2])
        XCTAssertEqual(Set(Cloud.allCases.filter { $0.capabilities.sessionLimit == 1 }), [.ftp, .sftp, .mega, .o2])
        XCTAssertEqual(Set(Cloud.allCases.filter { $0.capabilities.undoesTrash }), [.google, .box, .pcloud, .mega])
        XCTAssertEqual(Cloud.allCases.filter { $0.capabilities.asyncCopy }, [.microsoft])
        XCTAssertEqual(Cloud.allCases.filter { $0.capabilities.temporaryLinks }, [.s3, .azure])
        XCTAssertTrue(Account.demo.capabilities.undoesTrash)
        XCTAssertFalse(Account.demo.capabilities.asyncCopy, "La demo copia al momento aunque se presente como Google")
    }
}
