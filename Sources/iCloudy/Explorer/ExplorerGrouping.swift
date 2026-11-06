import Foundation

/// How the list view gathers its rows under headings.
enum FileGrouping: String, CaseIterable, Identifiable {
    case none, kind, date
    /// Only the global search mixes accounts; in a folder every row has the same one.
    case account
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return L("Sin agrupar")
        case .kind: return L("Por tipo")
        case .date: return L("Por fecha de modificación")
        case .account: return L("Por cuenta")
        }
    }
    /// What a folder can be grouped by; the account grouping belongs to the global search.
    static let forFolders: [FileGrouping] = [.none, .kind, .date]
}

/// A heading of a grouped list and the rows under it, in the order the list sorts them.
struct FileGroup<Item>: Identifiable {
    let id: String
    let title: String
    var items: [Item]
}

/// The periods the date grouping uses, newest first, the way the Finder names them.
enum DateBucket: Int, CaseIterable {
    case today, yesterday, week, month, year, older, unknown
    var title: String {
        switch self {
        case .today: return L("Hoy")
        case .yesterday: return L("Ayer")
        case .week: return L("Últimos 7 días")
        case .month: return L("Últimos 30 días")
        case .year: return L("Este año")
        case .older: return L("Antes")
        case .unknown: return L("Sin fecha")
        }
    }
    static func of(_ date: Date?, now: Date, calendar: Calendar) -> DateBucket {
        guard let date else { return .unknown }
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return .yesterday }
        let start = calendar.startOfDay(for: now)
        if let week = calendar.date(byAdding: .day, value: -7, to: start), date >= week { return .week }
        if let month = calendar.date(byAdding: .day, value: -30, to: start), date >= month { return .month }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) { return .year }
        return .older
    }
}

extension FileKind {
    /// The heading of this kind's group: the family, in the plural.
    var groupTitle: String {
        switch self {
        case .folder: return L("Carpetas")
        case .pdf: return L("PDF")
        case .document: return L("Documentos")
        case .spreadsheet: return L("Hojas de cálculo")
        case .presentation: return L("Presentaciones")
        case .image: return L("Imágenes")
        case .video: return L("Vídeos")
        case .audio: return L("Audio")
        case .archive: return L("Archivos comprimidos")
        case .code: return L("Código")
        case .text: return L("Texto")
        case .font: return L("Tipos de letra")
        case .disk: return L("Imágenes de disco")
        case .generic: return L("Otros")
        }
    }
}

extension FileGrouping {
    /// Splits `items`, already sorted, into this grouping's headings. Each group keeps the sort order; the groups
    /// themselves go in a fixed order (kinds as `FileKind` declares them, dates newest first, accounts as the sidebar
    /// lists them). `.none` is one untitled group.
    func groups<Item>(_ items: [Item], file: (Item) -> CloudFile, accountID: (Item) -> String? = { _ in nil },
                      accountOrder: [String] = [], accountTitle: (String) -> String = { $0 },
                      now: Date = Date(), calendar: Calendar = .current) -> [FileGroup<Item>] {
        switch self {
        case .none:
            return [FileGroup(id: "all", title: "", items: items)]
        case .kind:
            return bucket(items, key: { file($0).kind }, order: { $0.rank }, id: { $0.rawValue }, title: { $0.groupTitle })
        case .date:
            return bucket(items, key: { DateBucket.of(file($0).modified, now: now, calendar: calendar) }, order: { $0.rawValue },
                          id: { "date-\($0.rawValue)" }, title: { $0.title })
        case .account:
            return bucket(items, key: { accountID($0) ?? "" }, order: { accountOrder.firstIndex(of: $0) ?? accountOrder.count },
                          id: { "account-" + $0 }, title: { $0.isEmpty ? L("Sin cuenta") : accountTitle($0) })
        }
    }

    private func bucket<Item, Key: Hashable>(_ items: [Item], key: (Item) -> Key, order: (Key) -> Int, id: (Key) -> String,
                                             title: (Key) -> String) -> [FileGroup<Item>] {
        var buckets: [Key: [Item]] = [:], seen: [Key] = []
        for item in items {
            let k = key(item)
            if buckets[k] == nil { seen.append(k) }
            buckets[k, default: []].append(item)
        }
        // Stable for equal ranks: the order in which the list first met each key.
        let sorted = seen.enumerated().sorted { a, b in
            let (ra, rb) = (order(a.element), order(b.element))
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        return sorted.map { FileGroup(id: id($0), title: title($0), items: buckets[$0] ?? []) }
    }
}

extension AppModel {
    /// The rows of a pane's list under the headings the settings ask for.
    func groupedFiles(inPane pane: Int, now: Date = Date()) -> [FileGroup<CloudFile>] {
        explorer.grouping.groups(tab(inPane: pane).visibleFiles, file: { $0 }, now: now)
    }

    /// The global search's hits under the headings chosen there, which may be the account each one came from.
    func groupedHits(_ hits: [SearchHit], now: Date = Date()) -> [FileGroup<SearchHit>] {
        explorer.searchGrouping.groups(hits, file: \.file, accountID: \.accountID, accountOrder: accounts.map(\.id),
                                       accountTitle: { [weak self] id in
            guard let self, let account = accounts.first(where: { $0.id == id }) else { return id }
            return accountTitle(account) + " · " + account.email
        }, now: now)
    }
}
