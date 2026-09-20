import Foundation

enum Collection: String, Codable, CaseIterable, Identifiable {
    case files, recent, shared
    var id: String { rawValue }
    var title: String {
        switch self { case .files: return L("Mis archivos"); case .recent: return "Recientes"; case .shared: return L("Compartido conmigo") }
    }
    var icon: String {
        switch self { case .files: return "folder"; case .recent: return "clock"; case .shared: return "person.2" }
    }
    /// Pseudo-parent handed to `CloudAPI.list`; never a real item id.
    var rootID: String {
        switch self { case .files: return "root"; case .recent: return "recent"; case .shared: return "sharedWithMe" }
    }
    static let virtualRoots: Set<String> = [Collection.recent.rootID, Collection.shared.rootID]
}
