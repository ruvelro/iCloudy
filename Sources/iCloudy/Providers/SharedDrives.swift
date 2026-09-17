import Foundation

/// A shared drive of Google Drive or a document library of SharePoint and OneDrive for Business. Both are the same
/// APIs iCloudy already speaks, addressed with a drive identifier instead of the signed-in user's own drive, so an
/// account scoped to one reuses every listing, transfer and search path unchanged.
struct RemoteDrive: Identifiable, Hashable {
    let id: String
    let name: String
    /// Where it lives, to tell apart libraries that share a name across sites.
    let detail: String
}

extension CloudAPI {
    /// Shared drives or document libraries this account can reach. Only Google and Microsoft have the concept.
    func availableDrives() async throws -> [RemoteDrive] {
        switch account.cloud {
        case .google:
            let result = try await json(URL(string: "https://www.googleapis.com/drive/v3/drives?pageSize=100&fields=drives(id,name)")!)
            return (result["drives"] as? [[String: Any]] ?? []).compactMap { value in
                guard let id = value["id"] as? String, let name = value["name"] as? String else { return nil }
                return RemoteDrive(id: id, name: name, detail: L("Unidad compartida de Google Drive"))
            }
        case .microsoft:
            var drives: [RemoteDrive] = []
            var seen: Set<String> = []
            // The sites the user follows, plus the tenant's root site, is a useful set without crawling everything.
            var sites: [(id: String, name: String)] = []
            if let root = try? await json(URL(string: "https://graph.microsoft.com/v1.0/sites/root?$select=id,displayName")!),
               let id = root["id"] as? String {
                sites.append((id, root["displayName"] as? String ?? L("Sitio principal")))
            }
            if let followed = try? await json(URL(string: "https://graph.microsoft.com/v1.0/me/followedSites?$select=id,displayName")!) {
                for value in followed["value"] as? [[String: Any]] ?? [] {
                    guard let id = value["id"] as? String else { continue }
                    sites.append((id, value["displayName"] as? String ?? id))
                }
            }
            for site in sites.prefix(12) {
                guard let result = try? await json(URL(string: "https://graph.microsoft.com/v1.0/sites/\(Self.segment(site.id))/drives?$select=id,name,driveType")!) else { continue }
                for value in result["value"] as? [[String: Any]] ?? [] {
                    guard let id = value["id"] as? String, seen.insert(id).inserted else { continue }
                    drives.append(RemoteDrive(id: id, name: value["name"] as? String ?? site.name, detail: site.name))
                }
            }
            return drives
        default:
            throw CloudError.message(L("\(account.cloud.title) no tiene unidades compartidas."))
        }
    }
}
