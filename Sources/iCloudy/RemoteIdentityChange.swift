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
        var newID = file.id
        if demo == nil {
            switch account.cloud {
            case .dropbox:
                newID = Self.dropboxJoin(destination.map(dropboxPath) ?? Self.dropboxParent(file.id), name).lowercased()
            case .ftp:
                newID = FTPListing.join(try destination.map(ftpPath) ?? (file.id as NSString).deletingLastPathComponent, name)
            case .volume:
                newID = try (destination.map(volumeURL) ?? volumeURL(file.id).deletingLastPathComponent()).appendingPathComponent(name).standardizedFileURL.path
            case .webdav:
                let parent = destination.map { Self.webdavNormalize($0 == "root" ? "/" : $0) } ?? Self.dropboxParent(Self.webdavNormalize(file.id))
                let leaf = destination == nil ? name : Self.webdavName(file.id)
                newID = Self.webdavNormalize(parent + "/" + leaf)
            default: break
            }
        }
        return RemoteIdentityChange(oldID: file.id, newID: newID, name: name, descendants: file.isFolder)
    }
}
