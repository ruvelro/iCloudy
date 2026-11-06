import Foundation
import SwiftUI

/// What a list can be sorted by. The raw values are what `BrowserState.sortMode` stores, so tabs saved before this
/// type existed read back the same.
enum SortKey: String, CaseIterable, Identifiable {
    case name, date, size, kind
    var id: String { rawValue }

    static func of(_ mode: String) -> SortKey { SortKey(rawValue: mode) ?? .name }

    var title: String {
        switch self {
        case .name: return L("Nombre")
        case .date: return L("Fecha de modificación")
        case .size: return L("Tamaño")
        case .kind: return L("Tipo")
        }
    }
    var symbol: String {
        switch self {
        case .name: return "textformat"
        case .date: return "clock"
        case .size: return "arrow.up.arrow.down"
        case .kind: return "square.stack.3d.up"
        }
    }
    /// The direction a key starts in when it is chosen: names and kinds A to Z, dates and sizes newest and largest
    /// first, which is what the menu offered before it had a direction at all.
    var defaultAscending: Bool { self == .name || self == .kind }

    /// What the two directions are called for this key, so the menu reads "Más recientes primero" rather than an
    /// abstract "Descendente" next to a date.
    func directionTitle(ascending: Bool) -> String {
        switch self {
        case .name, .kind: return ascending ? L("De la A a la Z") : L("De la Z a la A")
        case .date: return ascending ? L("Más antiguos primero") : L("Más recientes primero")
        case .size: return ascending ? L("Más pequeños primero") : L("Más grandes primero")
        }
    }

    /// Compares on this key alone; ties are for the caller to break.
    func compare(_ a: CloudFile, _ b: CloudFile) -> Foundation.ComparisonResult {
        switch self {
        case .name: return a.name.localizedStandardCompare(b.name)
        case .date: return Self.order(a.sortDate, b.sortDate)
        case .size: return Self.order(a.sortSize, b.sortSize)
        case .kind: return a.kindSortKey.compare(b.kindSortKey)
        }
    }
    private static func order<T: Comparable>(_ a: T, _ b: T) -> Foundation.ComparisonResult {
        a == b ? .orderedSame : (a < b ? .orderedAscending : .orderedDescending)
    }

    /// The table column this key sorts, as the key path its header compares by.
    var keyPath: PartialKeyPath<CloudFile> {
        switch self {
        case .name: return \CloudFile.name
        case .date: return \CloudFile.sortDate
        case .size: return \CloudFile.sortSize
        case .kind: return \CloudFile.kindSortKey
        }
    }

    /// The comparator a `Table` header shows for this key and direction.
    func comparator(ascending: Bool) -> KeyPathComparator<CloudFile> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return KeyPathComparator(\CloudFile.name, order: order)
        case .date: return KeyPathComparator(\CloudFile.sortDate, order: order)
        case .size: return KeyPathComparator(\CloudFile.sortSize, order: order)
        case .kind: return KeyPathComparator(\CloudFile.kindSortKey, order: order)
        }
    }

    /// The key and direction a header click asked for, or nil for a comparator no column of the explorer makes.
    static func from(_ comparators: [KeyPathComparator<CloudFile>]) -> (key: SortKey, ascending: Bool)? {
        guard let first = comparators.first, let key = allCases.first(where: { $0.keyPath == first.keyPath }) else { return nil }
        return (key, first.order == .forward)
    }
}

extension CloudFile {
    /// Comparable stand-ins for the optional fields, so a table column can sort by them. Unknown dates and sizes go
    /// to the far end, where they are least in the way.
    var sortDate: Date { modified ?? .distantPast }
    var sortSize: Int64 { size ?? -1 }
    /// Kind first, in `FileKind`'s order, then the extension, so PDFs sit together and the JPEGs among the images do too.
    var kindSortKey: String {
        String(format: "%03d", kind.rank) + "." + (name as NSString).pathExtension.lowercased()
    }
}

extension AppModel {
    /// The focused tab's direction. Choosing a key through `sortMode` resets it to that key's own.
    var sortAscending: Bool {
        get { workspace.current.sortAscending }
        set { workspace.current.sortAscending = newValue }
    }

    /// What a pane's table header shows and changes: the tab's key and direction as one comparator.
    func sortOrder(inPane pane: Int) -> Binding<[KeyPathComparator<CloudFile>]> {
        Binding(get: {
            let tab = self.tab(inPane: pane)
            return [SortKey.of(tab.sortMode).comparator(ascending: tab.sortAscending)]
        }, set: { comparators in
            guard let (key, ascending) = SortKey.from(comparators) else { return }
            self.workspace.update(self.tab(inPane: pane).id) { $0.sort(by: key.rawValue, ascending: ascending) }
        })
    }
}
