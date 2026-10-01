import Foundation

struct CloudFile: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let mime: String
    let size: Int64?
    let modified: Date?
    let webURL: URL?
    let isFolder: Bool
    /// The content checksum the provider listed with the item, when it lists one. Downloads are checked against it.
    var checksum: ContentHash? = nil
    var isGoogleDocument: Bool { mime.hasPrefix("application/vnd.google-apps.") && !isFolder }
    /// What a Google document becomes when it leaves Drive: an Office file it can round-trip, or PDF for drawings.
    var crossCloudExport: (mime: String, ext: String)? {
        switch mime {
        case "application/vnd.google-apps.document": return ("application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")
        case "application/vnd.google-apps.spreadsheet": return ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx")
        case "application/vnd.google-apps.presentation": return ("application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx")
        case "application/vnd.google-apps.drawing": return ("application/pdf", "pdf")
        default: return nil
        }
    }
    var exportOptions: [(title: String, mime: String, ext: String)] {
        switch mime {
        case "application/vnd.google-apps.document": return [("PDF", "application/pdf", "pdf"), ("Word", "application/vnd.openxmlformats-officedocument.wordprocessingml.document", "docx")]
        case "application/vnd.google-apps.spreadsheet": return [("Excel", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet", "xlsx"), ("PDF", "application/pdf", "pdf")]
        case "application/vnd.google-apps.presentation": return [("PowerPoint", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "pptx"), ("PDF", "application/pdf", "pdf")]
        default: return []
        }
    }
    var icon: String {
        if isFolder { return "folder.fill" }
        if isGoogleDocument { return "doc.richtext" }
        if mime.hasPrefix("image/") { return "photo" }
        if mime.hasPrefix("video/") { return "film" }
        return "doc"
    }
}

extension CloudFile {
    enum CodingKeys: String, CodingKey { case id, name, mime, size, modified, webURL, isFolder, checksum }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let mime = try values.decodeIfPresent(String.self, forKey: .mime) ?? "application/octet-stream"
        self.init(id: try values.decode(String.self, forKey: .id),
                  name: try values.decodeIfPresent(String.self, forKey: .name) ?? "archivo",
                  mime: mime,
                  size: try values.decodeIfPresent(Int64.self, forKey: .size),
                  modified: try values.decodeIfPresent(Date.self, forKey: .modified),
                  webURL: try values.decodeIfPresent(URL.self, forKey: .webURL),
                  isFolder: try values.decodeIfPresent(Bool.self, forKey: .isFolder) ?? (mime == "application/vnd.google-apps.folder"),
                  // An algorithm written by a newer version is dropped rather than making the whole queue unreadable.
                  checksum: (try? values.decodeIfPresent(ContentHash.self, forKey: .checksum)) ?? nil)
    }
}

/// A checksum as the provider spells it: hexadecimal for the classic digests, Base64 for Microsoft's QuickXorHash.
struct ContentHash: Codable, Hashable {
    enum Algorithm: String, Codable {
        case md5, sha1, sha256
        /// Microsoft's 160-bit XOR-and-shift hash, the only one OneDrive lists for every account type.
        case quickXor
        /// Dropbox's `content_hash`: SHA-256 over the SHA-256 of every 4 MiB block.
        case dropbox
    }
    let algorithm: Algorithm
    let value: String
    /// Compares a digest computed here with the listed one, in the notation `ContentHasher` produces.
    func matches(_ computed: String) -> Bool {
        if algorithm == .quickXor, let listed = Data(base64Encoded: value), let mine = Data(base64Encoded: computed) { return listed == mine }
        return value.lowercased() == computed.lowercased()
    }
}
