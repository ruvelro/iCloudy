import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// A column of the explorer's list. The raw value is the column's customization identifier, which is what the table
/// stores its visibility, width and order under.
enum FileColumn: String, CaseIterable, Identifiable {
    case name, modified, size, kind, checksum, status
    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return L("Nombre")
        case .modified: return L("Modificado")
        case .size: return L("Tamaño")
        case .kind: return L("Tipo")
        case .checksum: return L("Suma de comprobación")
        case .status: return L("Estado")
        }
    }
    /// What a list shows before anybody changes it: the three columns it always had.
    var defaultVisible: Bool { [.name, .modified, .size].contains(self) }
    /// The name is what a row is; hiding it would leave rows nobody can tell apart.
    var canHide: Bool { self != .name }
}

/// How the explorer's lists are drawn, for every tab and window alike: which columns show, how wide and in what order.
/// Kept in the preferences, like the view mode, because it is a matter of taste rather than of any one place.
@MainActor
@Observable
final class ExplorerSettings {
    static let columnsKey = "explorerColumns"

    /// The table's own record of each column: visibility, width and order. The header's context menu edits it, and
    /// so does the View menu through `setVisible`.
    var columns: TableColumnCustomization<CloudFile> {
        didSet { if let data = try? JSONEncoder().encode(columns) { defaults.set(data, forKey: Self.columnsKey) } }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = Prefs.defaults) {
        self.defaults = defaults
        // A value written by another version, or by hand, costs the column layout and nothing else.
        columns = defaults.data(forKey: Self.columnsKey).flatMap { try? JSONDecoder().decode(TableColumnCustomization<CloudFile>.self, from: $0) }
            ?? TableColumnCustomization()
    }

    func isVisible(_ column: FileColumn) -> Bool {
        guard column.canHide else { return true }
        switch columns[visibility: column.rawValue] {
        case .visible: return true
        case .hidden: return false
        default: return column.defaultVisible
        }
    }

    func setVisible(_ column: FileColumn, _ visible: Bool) {
        guard column.canHide else { return }
        columns[visibility: column.rawValue] = visible ? .visible : .hidden
    }

    func visibility(of column: FileColumn) -> Binding<Bool> {
        Binding(get: { self.isVisible(column) }, set: { self.setVisible(column, $0) })
    }
}

extension CloudFile {
    /// What the item is, in words: the system's own name for the type where it knows the extension, so a `.key`
    /// reads "Keynote Presentation" in the language the Mac is set to.
    var kindDescription: String {
        if isFolder { return L("Carpeta") }
        switch mime {
        case "application/vnd.google-apps.document": return L("Documento de Google")
        case "application/vnd.google-apps.spreadsheet": return L("Hoja de cálculo de Google")
        case "application/vnd.google-apps.presentation": return L("Presentación de Google")
        case _ where isGoogleDocument: return L("Archivo de Google")
        default: break
        }
        let ext = (name as NSString).pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext), let description = type.localizedDescription { return description }
        if let type = UTType(mimeType: mime), type != .data, let description = type.localizedDescription { return description }
        return L("Documento")
    }

    /// The listed checksum, short enough for a column: the algorithm and the first characters of the value.
    var checksumSummary: String? {
        guard let checksum else { return nil }
        return checksum.algorithm.title + " " + checksum.value.prefix(12) + (checksum.value.count > 12 ? "…" : "")
    }
}

extension AppModel {
    /// The Estado column and the inspector's summary: what iCloudy knows about this item beyond the cloud listing.
    func statusDescription(_ file: CloudFile, in tab: BrowserState) -> String {
        var parts: [String] = []
        let local = localStatus(file, in: tab)
        if !file.isFolder, local != .cloudOnly { parts.append(local.label) }
        if let offline = offlineStatus(file, in: tab) { parts.append(offline.label) }
        return parts.isEmpty ? (file.isFolder ? "" : L("Solo en la nube")) : parts.joined(separator: " · ")
    }
}
