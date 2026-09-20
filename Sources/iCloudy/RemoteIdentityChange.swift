import Foundation

/// A server mutation can change the identity of every descendant for path-addressed providers.
struct RemoteIdentityChange {
    let oldID: String
    let newID: String
    let name: String
    let descendants: Bool
    func id(_ value: String) -> String {
        if value == oldID { return newID }
        let prefix = oldID.hasSuffix("/") ? oldID : oldID + "/"
        if descendants, oldID != newID, value.hasPrefix(prefix) {
            return (newID.hasSuffix("/") ? newID : newID + "/") + value.dropFirst(prefix.count)
        }
        return value
    }
    func treeKey(_ value: String) -> String {
        guard oldID != newID else { return value }
        let pattern = "(?<=/)" + NSRegularExpression.escapedPattern(for: oldID) + "(?=/|$)"
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        return expression.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value),
                                                   withTemplate: NSRegularExpression.escapedTemplate(for: newID))
    }
    func file(_ value: CloudFile) -> CloudFile {
        let updated = id(value.id)
        return CloudFile(id: updated, name: value.id == oldID ? name : value.name, mime: value.mime,
                         size: value.size, modified: value.modified, webURL: updated == value.id ? value.webURL : nil, isFolder: value.isFolder)
    }
}

extension CloudAPI {
    func identityChange(file: CloudFile, name: String, destination: String? = nil) throws -> RemoteIdentityChange {
        if demo != nil { return RemoteIdentityChange(oldID: file.id, newID: file.id, name: name, descendants: file.isFolder) }
        return try provider.identityChange(file: file, name: name, destination: destination)
    }
}
