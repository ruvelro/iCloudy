import Foundation

/// What a person may do with an item they were given access to. Two levels, because they are the two every
/// provider has; Drive's "commenter" is shown as a viewer, and Nextcloud's finer bits are folded the same way.
enum ShareRole: String, Codable, CaseIterable, Identifiable {
    case viewer, editor
    var id: String { rawValue }
    var title: String {
        switch self { case .viewer: return L("Puede ver"); case .editor: return L("Puede editar") }
    }
}

/// One grant of access on an item: a person, a group, a domain or a public link, as the provider lists it.
struct SharePermission: Identifiable, Hashable, Codable {
    enum Kind: String, Codable { case person, group, domain, link, pending }
    let id: String
    let kind: Kind
    /// The name the provider shows for the grantee; for a link, what kind of link it is.
    let name: String
    let email: String?
    /// Nil for the owner and for grants whose level the provider does not spell out.
    let role: ShareRole?
    let isOwner: Bool
    /// Access that comes from a parent folder cannot be revoked on this item.
    let isInherited: Bool
    var canRevoke: Bool { !isOwner && !isInherited }
    init(id: String, kind: Kind = .person, name: String, email: String? = nil, role: ShareRole?, isOwner: Bool = false, isInherited: Bool = false) {
        self.id = id; self.kind = kind; self.name = name; self.email = email; self.role = role; self.isOwner = isOwner; self.isInherited = isInherited
    }
}
