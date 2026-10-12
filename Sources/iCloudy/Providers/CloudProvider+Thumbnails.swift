import Foundation
import AppKit
import QuickLookThumbnailing

/// Thumbnails, where the provider draws them itself. Each one is a single request for a small image of at most
/// `ThumbnailRequest.maximumBytes`; nil means the provider has none for this item, which is common and not an error.
extension CloudProvider {
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? { nil }

    /// Reads a thumbnail and keeps it only when it is an image of reasonable size. Box answers 202 while it is still
    /// drawing one, and some providers answer a JSON error with a 200; neither is an image.
    func thumbnailData(_ request: URLRequest) async throws -> Data? {
        var request = request
        request.timeoutInterval = 30
        let (data, response) = try await send(&request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ThumbnailRequest.accepts(data) ? data : nil
    }
}

enum ThumbnailRequest {
    static let maximumBytes = 2_000_000
    /// Asks only for what is likely to have one: pictures, videos and PDFs. A thumbnail request for a text file would
    /// cost a round trip to learn there is nothing to draw.
    static func isCandidate(_ file: CloudFile) -> Bool {
        guard !file.isFolder, !file.isGoogleDocument else { return false }
        return [.image, .video, .pdf].contains(file.kind)
    }
    static func accepts(_ data: Data) -> Bool {
        !data.isEmpty && data.count <= maximumBytes && NSBitmapImageRep(data: data) != nil
    }
}

extension GoogleDriveProvider {
    /// `thumbnailLink` is short-lived and sized by its `=sNNN` suffix. It lives on googleusercontent.com, so the token
    /// goes there and nowhere else.
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? {
        let item = try await json(googleURL("https://www.googleapis.com/drive/v3/files/\(Self.segment(file.id))?fields=thumbnailLink"))
        guard let link = item["thumbnailLink"] as? String else { return nil }
        let sized = link.replacingOccurrences(of: #"=s\d+$"#, with: "=s\(side)", options: .regularExpression)
        guard let url = URL(string: sized), url.scheme == "https", let host = url.host, host.hasSuffix(".googleusercontent.com") else { return nil }
        return try await thumbnailData(request(url))
    }
}

extension OneDriveProvider {
    /// Graph draws a custom size with `c` (cropped) plus width and height.
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? {
        let url = URL(string: "\(graphDrive)/items/\(Self.segment(file.id))/thumbnails/0/c\(side)x\(side)/content")!
        return try await thumbnailData(request(url))
    }
}

extension DropboxProvider {
    /// Dropbox has a fixed menu of sizes; 256 is the one closest to what the grid draws on a Retina screen.
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? {
        var request = try await request(URL(string: "https://content.dropboxapi.com/2/files/get_thumbnail_v2")!, method: "POST")
        let size = side <= 128 ? "w128h128" : "w256h256"
        request.setValue(Self.asciiJSON(["resource": [".tag": "path", "path": dropboxPath(file.id)], "format": "jpeg", "size": size, "mode": "bestfit"]),
                         forHTTPHeaderField: "Dropbox-API-Arg")
        return try await thumbnailData(request)
    }
}

extension BoxProvider {
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? {
        var parts = URLComponents(string: "https://api.box.com/2.0/files/\(Self.segment(file.id))/thumbnail.jpg")!
        let box = side <= 160 ? 160 : 320 // Box renders 32, 94, 160 and 320
        parts.queryItems = [URLQueryItem(name: "min_width", value: "\(box)"), URLQueryItem(name: "min_height", value: "\(box)")]
        return try await thumbnailData(request(parts.url!))
    }
}

extension PCloudProvider {
    /// `getthumb` answers the image itself. Width and height have to be multiples of 4 or 5.
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? {
        let size = max(16, min(1024, side / 4 * 4))
        return try await thumbnailData(request(pcloudURL("getthumb", ["fileid": Self.numericID(file.id), "size": "\(size)x\(size)", "type": "jpg"])))
    }
}

extension VolumeProvider {
    /// The Finder's own thumbnails, drawn by Quick Look from the file on disk.
    func thumbnail(of file: CloudFile, side: Int) async throws -> Data? {
        try await ThumbnailRequest.quickLook(try volumeURL(file.id), side: side)
    }
}

extension ThumbnailRequest {
    @MainActor static func quickLook(_ url: URL, side: Int) async throws -> Data? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale, representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8])
    }
}
