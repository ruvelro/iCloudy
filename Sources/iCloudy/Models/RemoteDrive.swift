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

