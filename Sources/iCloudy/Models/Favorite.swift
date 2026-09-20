import Foundation

struct Favorite: Identifiable, Codable {
    var id: String { accountID + ":" + file.id }
    let accountID: String
    var file: CloudFile
    var path: [CloudFile]
    var collection: Collection = .files
}

extension Favorite {
    enum CodingKeys: String, CodingKey { case accountID, file, path, collection }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(accountID: try values.decode(String.self, forKey: .accountID),
                  file: try values.decode(CloudFile.self, forKey: .file),
                  path: try values.decodeIfPresent([CloudFile].self, forKey: .path) ?? [],
                  collection: try values.decodeIfPresent(String.self, forKey: .collection).flatMap(Collection.init(rawValue:)) ?? .files)
    }
}
