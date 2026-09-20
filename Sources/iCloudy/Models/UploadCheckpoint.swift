import Foundation

struct UploadCheckpoint: Codable {
    var url: URL?
    var offset: Int64 = 0
    var total: Int64 = 0
    var modified: Date?
    var complete = false
    /// Dropbox and Box identify an upload session by an opaque id rather than by a URL.
    var sessionID: String?
    /// Box needs every part it has accepted when the session is committed, as JSON fragments.
    var parts: [String] = []
    /// Block size imposed by the provider; Box chooses it when the session starts.
    var chunkSize: Int64?
    var integrity: UploadIntegrity?
    var remoteID: String?
    var sourceStamp: UploadSourceStamp?
    var pendingRetirementID: String?
}

extension UploadCheckpoint {
    enum CodingKeys: String, CodingKey { case url, offset, total, modified, complete, sessionID, parts, chunkSize, integrity, remoteID, sourceStamp, pendingRetirementID }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(url: try values.decodeIfPresent(URL.self, forKey: .url),
                  offset: try values.decodeIfPresent(Int64.self, forKey: .offset) ?? 0,
                  total: try values.decodeIfPresent(Int64.self, forKey: .total) ?? 0,
                  modified: try values.decodeIfPresent(Date.self, forKey: .modified),
                  complete: try values.decodeIfPresent(Bool.self, forKey: .complete) ?? false,
                  sessionID: try values.decodeIfPresent(String.self, forKey: .sessionID),
                  parts: try values.decodeIfPresent([String].self, forKey: .parts) ?? [],
                  chunkSize: try values.decodeIfPresent(Int64.self, forKey: .chunkSize),
                  integrity: try values.decodeIfPresent(UploadIntegrity.self, forKey: .integrity),
                  remoteID: try values.decodeIfPresent(String.self, forKey: .remoteID),
                  sourceStamp: try values.decodeIfPresent(UploadSourceStamp.self, forKey: .sourceStamp),
                  pendingRetirementID: try values.decodeIfPresent(String.self, forKey: .pendingRetirementID))
    }
}
