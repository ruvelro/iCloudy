import AppKit
import SwiftUI
import Quartz

/// A folder to compare or search: one of a connected account, or one of this Mac.
struct FolderLocation: Identifiable, Hashable {
    enum Place: Hashable {
        /// `folder` nil is the top of the account.
        case cloud(accountID: String, folder: CloudFile?)
        case local(URL)
    }
    var id = UUID()
    let place: Place
    /// Folder names from the top of the account down, for display only.
    var trail: [String] = []

    var accountID: String? { if case .cloud(let id, _) = place { return id } else { return nil } }
    var localURL: URL? { if case .local(let url) = place { return url } else { return nil } }

    /// Whether two locations name the same folder, whatever their display trail.
    func isSame(as other: FolderLocation) -> Bool {
        switch (place, other.place) {
        case (.cloud(let left, let a), .cloud(let right, let b)): return left == right && (a?.id ?? "root") == (b?.id ?? "root")
        case (.local(let a), .local(let b)): return a.standardizedFileURL.path == b.standardizedFileURL.path
        default: return false
        }
    }
}

/// Owns the comparison and duplicate windows' state and turns their results into the app's own actions: copies go
/// through the transfer queue, trash through each provider, previews through the preview window. One window serves
/// both tools, so it survives being closed and keeps what it found until the next run.
@MainActor
final class CompareCenter: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = CompareCenter()
    enum Mode: String { case compare, duplicates }

    weak var model: AppModel?
    private var window: NSWindow?
    @Published var mode = Mode.compare
    /// Off, nothing is read from the Mac: only what the providers list is compared.
    @Published var hashLocally = true

    // Comparison
    @Published var sideA: FolderLocation?
    @Published var sideB: FolderLocation?
    @Published private(set) var comparing = false
    @Published private(set) var compareProgress = ComparisonEngine.Progress()
    @Published private(set) var result = ComparisonResult()
    /// The rows of the chosen group, appended as they arrive rather than filtered again on every batch.
    @Published private(set) var visibleRows: [ComparisonRow] = []
    @Published var filter: ComparisonGroup? { didSet { visibleRows = result.rows.filter(matchesFilter) } }
    /// The folders the rows on screen came from. Copies use these, not whatever the pickers show now.
    @Published private(set) var compared: (a: FolderLocation, b: FolderLocation)?
    @Published var compareMessage: String?
    @Published var compareProblem: String?
    private var compareTask: Task<Void, Never>?
    private var pendingRows: [ComparisonRow] = []
    private var lastFlush = Date.distantPast

    // Duplicates
    @Published var roots: [FolderLocation] = []
    @Published private(set) var scanning = false
    @Published private(set) var scanProgress = DuplicateScanner.Progress()
    @Published private(set) var report: DuplicateReport?
    @Published private(set) var scannedRoots: [FolderLocation] = []
    @Published var marked: Set<String> = []
    @Published var confirmingTrash = false
    @Published private(set) var trashing = false
    @Published var scanMessage: String?
    @Published var scanProblem: String?
    private var scanTask: Task<Void, Never>?
    private var lastProgress = Date.distantPast

    // MARK: - Window

    func openCompare(model: AppModel, with folder: FolderLocation?) {
        self.model = model
        mode = .compare
        if let folder, !comparing { sideA = folder; if sideB?.isSame(as: folder) == true { sideB = nil } }
        show()
    }

    func openDuplicates(model: AppModel, in folder: FolderLocation?) {
        self.model = model
        mode = .duplicates
        if let folder, !scanning, !roots.contains(where: { $0.isSame(as: folder) }) { roots.append(folder) }
        show()
    }

    private func show() {
        guard let model else { return }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700),
                                   styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            created.isReleasedWhenClosed = false
            created.title = L("Comparar y buscar duplicados")
            created.minSize = NSSize(width: 860, height: 560)
            created.contentView = NSHostingView(rootView: CompareRootView(center: self, model: model))
            created.delegate = self
            created.center()
            created.setFrameAutosaveName("CompareWindow")
            window = created
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closing the window stops whatever is listing or hashing; what was already found stays for when it reopens.
    func windowWillClose(_ notification: Notification) {
        compareTask?.cancel()
        scanTask?.cancel()
    }

    // MARK: - Locations

    func account(_ id: String?) -> Account? { model?.accounts.first { $0.id == id } }

    func title(of location: FolderLocation) -> String {
        switch location.place {
        case .local(let url): return (url.path as NSString).abbreviatingWithTildeInPath
        case .cloud(let id, _):
            let place = location.trail.isEmpty ? L("Mis archivos") : location.trail.joined(separator: " / ")
            guard let account = account(id), let model else { return L("Cuenta desconectada") + " · " + place }
            return model.accountTitle(account) + " · " + place
        }
    }

    private func source(for location: FolderLocation) throws -> InventorySource {
        switch location.place {
        case .local(let url): return LocalInventorySource(root: url)
        case .cloud(let id, let folder):
            guard let model, let account = account(id) else { throw CloudError.message(L("Vuelve a conectar la cuenta de esta carpeta.")) }
            return CloudInventorySource(api: try model.client(account), rootID: folder?.id ?? Collection.files.rootID)
        }
    }

    /// Asks for a folder of this Mac. The open panel's grant lasts while the app runs, which covers comparing,
    /// hashing and any copy queued from the result.
    func pickLocalFolder() async -> FolderLocation? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("Elegir")
        guard await panel.begin() == .OK, let url = panel.url else { return nil }
        return FolderLocation(place: .local(url))
    }

    /// Throttles what the window redraws: a walk of a Mac folder reports thousands of steps a second.
    private func shouldReport() -> Bool {
        guard Date().timeIntervalSince(lastProgress) > 0.1 else { return false }
        lastProgress = Date()
        return true
    }

    // MARK: - Comparison

    static func problem(comparing a: FolderLocation, with b: FolderLocation) -> String? {
        if a.isSame(as: b) { return L("Elige dos carpetas distintas.") }
        if a.localURL != nil, b.localURL != nil { return L("Al menos una de las dos carpetas tiene que ser de una cuenta conectada. Dos carpetas del Mac se comparan mejor en el Finder.") }
        return nil
    }

    func startCompare() {
        guard let a = sideA, let b = sideB, !comparing else { return }
        compareMessage = nil; compareProblem = nil
        if let problem = Self.problem(comparing: a, with: b) { compareProblem = problem; return }
        let engine: ComparisonEngine
        do { engine = ComparisonEngine(a: try source(for: a), b: try source(for: b)) }
        catch { compareProblem = error.localizedDescription; return }
        engine.hashLocally = hashLocally
        result = ComparisonResult(); visibleRows = []; pendingRows = []
        compared = (a, b); compareProgress = ComparisonEngine.Progress(); comparing = true
        compareTask = Task {
            do {
                try await engine.run(progress: { [weak self] state in
                    guard let self, self.shouldReport() else { return }
                    self.compareProgress = state
                }, emit: { [weak self] rows in self?.receive(rows) })
            } catch {
                if Task.isCancelled { compareMessage = L("Comparación detenida. Lo encontrado hasta ahora se conserva.") }
                else { compareProblem = error.localizedDescription }
            }
            flush()
            comparing = false
        }
    }

    func cancelCompare() { compareTask?.cancel() }

    private func receive(_ rows: [ComparisonRow]) {
        pendingRows += rows
        if Date().timeIntervalSince(lastFlush) > 0.25 { flush() }
    }

    private func flush() {
        let kept = result.add(pendingRows)
        pendingRows = []
        visibleRows.append(contentsOf: kept.filter(matchesFilter))
        lastFlush = Date()
    }

    private func matchesFilter(_ row: ComparisonRow) -> Bool { filter == nil || row.status.group == filter }

    /// Rows that have something to copy from `side`: identical ones have nothing to add.
    func copyable(_ rows: [ComparisonRow], from side: ComparisonSide) -> [ComparisonRow] {
        rows.filter { (side == .a ? $0.a : $0.b) != nil && $0.status.group != .identical }
    }

    /// Queues copies of the chosen rows from one side to the other, through the same transfer queue as any upload,
    /// download or cloud-to-cloud copy. Each lands in the folder that holds it on the other side; a row whose name is
    /// already taken there stops at the queue's own question before anything is replaced.
    func copy(_ rows: [ComparisonRow], from side: ComparisonSide) {
        guard let model, let compared else { return }
        let source = side == .a ? compared.a : compared.b, target = side == .a ? compared.b : compared.a
        let items = copyable(rows, from: side).compactMap { row -> CopyItem? in
            guard let entry = side == .a ? row.a : row.b else { return nil }
            return CopyItem(entry: entry, parent: side == .a ? row.parentB : row.parentA, directory: row.directory)
        }
        guard !items.isEmpty else { return }
        do {
            let place = title(of: target)
            let jobs = try Self.transfers(items, from: source, to: target, accounts: model.accounts,
                                          label: { place + ($0.isEmpty ? "" : " / " + $0) }, scratch: model.queue.scratchDirectory(for:))
            try model.queue.add(jobs)
            compareMessage = L("\(jobs.count) copias en cola. Sigue el progreso en Transferencias, en la ventana principal; si el destino ya tiene un archivo con ese nombre, iCloudy preguntará allí antes de reemplazarlo. Vuelve a comparar cuando terminen.")
        } catch { compareProblem = error.localizedDescription }
    }

    /// One item to copy: what it is, the folder on the other side that receives it (nil is the compared folder),
    /// and where that is relative to the compared folders, for the transfer's label.
    struct CopyItem {
        let entry: InventoryEntry
        let parent: InventoryEntry?
        let directory: String
    }

    /// The transfer jobs for a copy, one per item, in one batch: cloud to cloud stages through a scratch folder, Mac to
    /// cloud uploads and cloud to Mac downloads, each into the counterpart folder found by the comparison.
    static func transfers(_ items: [CopyItem], from source: FolderLocation, to target: FolderLocation, accounts: [Account],
                          label: (String) -> String, scratch: (UUID) -> URL) throws -> [Transfer] {
        let batch = UUID()
        func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
        switch (source.place, target.place) {
        case (.cloud(let sourceID, _), .cloud(let targetID, let top)):
            guard let from = account(sourceID), let to = account(targetID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de esta carpeta.")) }
            return items.compactMap { item in
                guard let file = item.entry.file else { return nil }
                var job = Transfer(batchID: batch, name: file.name, destination: label(item.directory), accountID: from.id, direction: .transfer,
                                   localURL: URL(fileURLWithPath: "/"), parent: item.parent?.file?.id ?? top?.id ?? Collection.files.rootID, file: file)
                job.localURL = scratch(job.id)
                job.targetAccountID = to.id
                return job
            }
        case (.local(let root), .cloud(let targetID, let top)):
            guard let to = account(targetID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de esta carpeta.")) }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            return try items.compactMap { item in
                guard let url = item.entry.url else { return nil }
                return Transfer(batchID: batch, name: url.lastPathComponent, destination: label(item.directory), accountID: to.id, direction: .upload,
                                localURL: url, bookmark: try TransferQueue.bookmark(url), parent: item.parent?.file?.id ?? top?.id ?? Collection.files.rootID)
            }
        case (.cloud(let sourceID, _), .local(let root)):
            guard let from = account(sourceID) else { throw CloudError.message(L("Vuelve a conectar la cuenta de esta carpeta.")) }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            return try items.compactMap { item in
                guard let file = item.entry.file else { return nil }
                let folder = item.parent?.url ?? root
                return Transfer(batchID: batch, name: file.name, destination: folder.path, accountID: from.id, direction: .download,
                                localURL: folder, bookmark: try TransferQueue.bookmark(folder), file: file)
            }
        case (.local, .local):
            throw CloudError.message(L("Al menos una de las dos carpetas tiene que ser de una cuenta conectada. Dos carpetas del Mac se comparan mejor en el Finder."))
        }
    }

    // MARK: - Reveal and preview

    /// Shows the item where it lives: in the Finder for the Mac, in the explorer for an account.
    func reveal(_ entry: InventoryEntry, parent: InventoryEntry?, in location: FolderLocation) {
        guard let model else { return }
        switch location.place {
        case .local:
            if let url = entry.url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .cloud(let accountID, let top):
            if let folder = parent?.file?.id ?? top?.id { model.openFolder(accountID: accountID, folderID: folder) }
            else { model.select(accountID) }
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0 !== window && $0.canBecomeMain && $0.isVisible }?.makeKeyAndOrderFront(nil)
        }
    }

    func canPreview(_ entry: InventoryEntry?) -> Bool { entry.map { !$0.isFolder } ?? false }

    func preview(_ entry: InventoryEntry, in location: FolderLocation) {
        guard let model, !entry.isFolder else { return }
        switch location.place {
        case .local:
            if let url = entry.url { LocalQuickLook.shared.show(url) }
        case .cloud(let accountID, _):
            guard let account = account(accountID), let file = entry.file else { return }
            do { model.preview.show(file: file, account: account, client: try model.client(account)) }
            catch { compareProblem = error.localizedDescription }
        }
    }

    // MARK: - Duplicates

    func startScan() {
        guard !roots.isEmpty, !scanning else { return }
        scanMessage = nil; scanProblem = nil
        let scanner = DuplicateScanner()
        scanner.hashLocally = hashLocally
        let sources: [DuplicateScanner.Root]
        do { sources = try roots.map { DuplicateScanner.Root(key: $0.accountID ?? "local", source: try source(for: $0)) } }
        catch { scanProblem = error.localizedDescription; return }
        report = nil; marked = []; scannedRoots = roots
        scanProgress = DuplicateScanner.Progress(); scanning = true
        scanTask = Task {
            do {
                report = try await scanner.run(sources) { [weak self] state in
                    guard let self, self.shouldReport() else { return }
                    self.scanProgress = state
                }
            } catch {
                if Task.isCancelled { scanMessage = L("Búsqueda detenida. Vuelve a empezarla para ver resultados.") }
                else { scanProblem = error.localizedDescription }
            }
            scanning = false
        }
    }

    func cancelScan() { scanTask?.cancel() }

    var markedCandidates: [DuplicateCandidate] { report?.groups.flatMap(\.members).filter { marked.contains($0.id) } ?? [] }
    var markedBytes: Int64 { markedCandidates.reduce(0) { $0 + ($1.entry.size ?? 0) } }
    /// True while every group keeps at least one copy that is not marked. Nothing is sent anywhere otherwise.
    var marksLeaveACopy: Bool { DuplicateGrouping.leavesACopy(marked, in: report?.groups ?? []) }
    var canTrash: Bool { !marked.isEmpty && !trashing && !scanning && marksLeaveACopy }

    func markSuggested() { marked = DuplicateGrouping.suggestedSelection(report?.groups ?? []) }

    func location(of candidate: DuplicateCandidate) -> FolderLocation? {
        scannedRoots.indices.contains(candidate.rootIndex) ? scannedRoots[candidate.rootIndex] : nil
    }

    /// Accounts among the marked files where deleting is final, by name. The confirmation lists them.
    var permanentDeletions: [String] {
        let ids = Set(markedCandidates.compactMap { location(of: $0)?.accountID })
        return ids.compactMap { account($0) }.filter { !$0.capabilities.reversibleTrash }.compactMap { account in model?.accountTitle(account) }.sorted()
    }

    /// Sends the marked files to their trash, one by one, and stops at the first failure so that what is left on
    /// screen is exactly what is left in the clouds. Never called without the confirmation.
    func trashMarked() async {
        guard let model, let report, canTrash else { return }
        let chosen = markedCandidates, permanent = !permanentDeletions.isEmpty
        trashing = true
        var done: Set<String> = [], touched: Set<String> = []
        do {
            for candidate in chosen {
                try Task.checkCancellation()
                guard let location = location(of: candidate) else { continue }
                switch location.place {
                case .local:
                    guard let url = candidate.entry.url else { continue }
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                case .cloud(let accountID, _):
                    guard let account = account(accountID), let file = candidate.entry.file else {
                        throw CloudError.message(L("Vuelve a conectar la cuenta de esta carpeta."))
                    }
                    try await model.client(account).trash(file: file)
                    touched.insert(account.id)
                    model.spotlight.forget(accountID: account.id, fileID: file.id)
                    model.favorites.removeAll { $0.accountID == account.id && $0.file.id == file.id }
                }
                done.insert(candidate.id)
            }
            scanMessage = permanent ? L("\(done.count) archivos eliminados. Los de cuentas con papelera se pueden restaurar desde ella; el resto se ha borrado de forma definitiva.")
                                    : L("\(done.count) archivos enviados a la papelera.")
        } catch {
            scanProblem = (done.isEmpty ? "" : L("Se eliminaron \(done.count) de \(chosen.count) archivos. ")) + error.localizedDescription
        }
        self.report = DuplicateGrouping.removing(done, from: report)
        marked.subtract(done)
        trashing = false
        if !touched.isEmpty {
            do { try LocalStore.save(model.favorites, to: model.favoritesURL) } catch { scanProblem = error.localizedDescription }
        }
        for id in touched {
            if let account = account(id) { model.refreshStorage(account, force: true) }
            if model.selectedAccountID == id { model.reload(fresh: true) }
        }
    }
}

/// Quick Look for a file of this Mac, which needs no download and no account.
@MainActor
final class LocalQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = LocalQuickLook()
    private var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

extension AppModel {
    /// The folder the explorer shows, as a place to compare or search. Lists such as Recientes are not folders.
    var currentFolderLocation: FolderLocation? {
        guard let account, collection == .files else { return nil }
        return FolderLocation(place: .cloud(accountID: account.id, folder: path.last), trail: path.map(\.name))
    }

    /// A folder of the listing on screen, with the breadcrumbs that lead to it.
    func folderLocation(_ folder: CloudFile) -> FolderLocation? {
        guard let account, folder.isFolder else { return nil }
        return FolderLocation(place: .cloud(accountID: account.id, folder: folder), trail: (collection == .files ? path.map(\.name) : []) + [folder.name])
    }

    func openComparator(with folder: CloudFile? = nil) {
        CompareCenter.shared.openCompare(model: self, with: folder.flatMap(folderLocation) ?? currentFolderLocation)
    }

    func openDuplicateFinder(in folder: CloudFile? = nil) {
        CompareCenter.shared.openDuplicates(model: self, in: folder.flatMap(folderLocation) ?? currentFolderLocation)
    }
}
