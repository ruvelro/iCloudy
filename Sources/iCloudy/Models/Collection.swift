import Foundation

enum Collection: String, Codable, CaseIterable, Identifiable {
    case files, recent, shared, trash
    var id: String { rawValue }
    var title: String {
        switch self {
        case .files: return L("Mis archivos")
        case .recent: return L("Recientes")
        case .shared: return L("Compartido conmigo")
        case .trash: return L("Papelera")
        }
    }
    var icon: String {
        switch self { case .files: return "folder"; case .recent: return "clock"; case .shared: return "person.2"; case .trash: return "trash" }
    }
    /// Pseudo-parent handed to `CloudAPI.list`; never a real item id.
    var rootID: String {
        switch self { case .files: return "root"; case .recent: return "recent"; case .shared: return "sharedWithMe"; case .trash: return "trash" }
    }
    static let virtualRoots: Set<String> = [Collection.recent.rootID, Collection.shared.rootID, Collection.trash.rootID]
}
