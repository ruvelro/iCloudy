import AppKit
import SwiftUI
import Combine
import UniformTypeIdentifiers

/// What F5, F6 or a drag from one pane to the other turns into.
enum PaneTransfer: Equatable {
    /// Both panes show the same account: its own move or copy, straight into the other pane's folder.
    case sameAccount(move: Bool)
    /// Different accounts: a queued cloud-to-cloud copy. A move sends each original to the bin only once its copy
    /// arrived complete and verified, and asks first.
    case crossCloud(move: Bool)
    case refused(String)
}

/// A cross-cloud move waiting for the person to confirm it.
struct PaneMoveRequest: Identifiable {
    let id = UUID()
    let files: [CloudFile]
    let source: Account
    let target: Account
    let parent: String
    let destinationPath: [CloudFile]
}

/// Bookkeeping for moves between panes that outlives the call that started them: the originals of cross-cloud moves
/// whose copies are still on their way, and the items being dragged from one pane to the other.
@MainActor
final class PaneTransfers {
    struct Pending { let sourceAccountID: String; let file: CloudFile; let targetTitle: String }
    /// Keyed by the transfer job that copies the item. Only in memory: if iCloudy quits before the copy finishes,
    /// the move is left as a copy and the original stays where it was, which is the safe way to fail.
    var pending: [UUID: Pending] = [:]
    struct Drag { let token: String; let pane: Int; let files: [CloudFile] }
    var drag: Drag?
}

extension AppModel {
    var isSplit: Bool { workspace.split }

    /// ⌘⇧D and the toolbar button.
    func toggleSplit() {
        if workspace.split { closePane(workspace.otherPane ?? 1); return }
        workspace.setSplit(true)
        tabCameIntoView(workspace.panes[1].current.id)
    }

    /// Hides a pane; the one left keeps the focus and becomes the first.
    func closePane(_ pane: Int) {
        guard workspace.split else { return }
        // The preview shows something of the focused pane; if that pane goes, so does the preview.
        let wasFocused = workspace.focusedPane == pane
        workspace.closePane(pane)
        if wasFocused { preview.close() }
    }

    /// A click anywhere in a pane gives it the focus before the click does anything else, so every action that works
    /// on "the open folder" works on the pane that was clicked.
    func focusPane(_ pane: Int) { workspace.focus(pane) }

    /// Tab, with two panes.
    func focusOtherPane() { if let other = workspace.otherPane { workspace.focus(other) } }

    func tab(inPane pane: Int) -> BrowserState { workspace.panes[min(pane, workspace.panes.count - 1)].current }

    /// The selection of a given pane, for the list drawn in it. Selecting does not move the focus by itself: the
    /// click that selects has already done that, and a list that tidies its selection on its own must not.
    func selection(inPane pane: Int) -> Binding<Set<CloudFile.ID>> {
        Binding(get: { self.tab(inPane: pane).selection },
                set: { ids in self.workspace.update(self.tab(inPane: pane).id) { $0.selection = ids } })
    }

    /// The filter of a given pane.
    func search(inPane pane: Int) -> Binding<String> {
        Binding(get: { self.tab(inPane: pane).search },
                set: { term in self.workspace.update(self.tab(inPane: pane).id) { $0.search = term } })
    }

    func isFavorite(_ file: CloudFile, in tab: BrowserState) -> Bool { favoriteKeys.contains((tab.accountID ?? "") + ":" + file.id) }

    func localStatus(_ file: CloudFile, in tab: BrowserState) -> LocalCopyStatus {
        guard let id = tab.accountID else { return .cloudOnly }
        return localCopies.status(for: file, accountID: id)
    }

    func account(of tab: BrowserState) -> Account? { accounts.first { $0.id == tab.accountID } }

    // MARK: - From one pane to the other

    /// Decides what sending `files` from the place `source` shows to the place `target` shows means, without doing it.
    static func paneTransfer(_ files: [CloudFile], from source: BrowserState, account sourceAccount: Account?,
                             to target: BrowserState, account targetAccount: Account?, move: Bool) -> PaneTransfer {
        guard !files.isEmpty else { return .refused(L("Selecciona lo que quieras copiar o mover al otro panel.")) }
        guard let sourceAccount, let targetAccount else { return .refused(L("Abre una cuenta en los dos paneles.")) }
        guard source.collection != .trash else { return .refused(L("Lo que está en la papelera se restaura; no se copia ni se mueve.")) }
        guard target.isWritableLocation, target.collection != .trash else {
            return .refused(L("Abre una carpeta de «Mis archivos» en el otro panel para copiar o mover ahí."))
        }
        let ids = Set(files.map(\.id))
        if sourceAccount.id == targetAccount.id {
            guard target.folderID != source.folderID || !source.isWritableLocation else {
                return .refused(L("Los dos paneles muestran la misma carpeta."))
            }
            guard !ids.contains(target.folderID), !target.path.contains(where: { ids.contains($0.id) }) else {
                return .refused(L("Una carpeta no puede moverse ni copiarse dentro de sí misma."))
            }
            if !move, let reason = sourceAccount.limitation(.copy, for: files) { return .refused(reason) }
            return .sameAccount(move: move)
        }
        // A Google document leaves Drive converted to Office or PDF: a copy, but not the same thing, so the original
        // is not sent to the bin on the strength of it.
        if move, let document = files.first(where: \.isGoogleDocument) {
            return .refused(L("«\(document.name)» es un documento de Google y llegaría convertido a otro formato. Cópialo en lugar de moverlo."))
        }
        return .crossCloud(move: move)
    }

    /// F5 and F6: the focused pane's selection to the other pane's folder.
    func sendSelectionToOtherPane(move: Bool) {
        guard let other = workspace.otherPane else { return }
        sendToPane(selection(selectedIDs), from: workspace.focusedPane, to: other, move: move)
    }

    func sendToPane(_ files: [CloudFile], from sourcePane: Int, to targetPane: Int, move: Bool) {
        guard workspace.visiblePanes.contains(sourcePane), workspace.visiblePanes.contains(targetPane), sourcePane != targetPane else { return }
        let source = tab(inPane: sourcePane), target = tab(inPane: targetPane)
        let plan = Self.paneTransfer(files, from: source, account: account(of: source), to: target, account: account(of: target), move: move)
        switch plan {
        case .refused(let reason): error = reason
        case .sameAccount(let move):
            guard let account = account(of: source) else { return }
            let request = Relocation(files: files, kind: move ? .move : .copy, account: account,
                                     origin: source.isWritableLocation ? source.folderID : nil)
            Task { await relocate(request, to: target.folderID, destinationPath: target.path) }
        case .crossCloud(false):
            guard let from = account(of: source), let to = account(of: target) else { return }
            enqueueCrossCloud(files, from: from, to: to, parent: target.folderID, destinationPath: target.path)
        case .crossCloud(true):
            guard let from = account(of: source), let to = account(of: target) else { return }
            pendingPaneMove = PaneMoveRequest(files: files, source: from, target: to, parent: target.folderID, destinationPath: target.path)
        }
    }

    /// The confirmed cross-cloud move: copies are queued as usual, and each original waits for its own copy.
    func startPaneMove(_ request: PaneMoveRequest) {
        let jobs = enqueueCrossCloud(request.files, from: request.source, to: request.target, parent: request.parent, destinationPath: request.destinationPath)
        let title = accountTitle(request.target)
        for (job, file) in zip(jobs, request.files) {
            paneTransfers.pending[job.id] = PaneTransfers.Pending(sourceAccountID: request.source.id, file: file, targetTitle: title)
        }
        if !jobs.isEmpty {
            info = L("Se copia a \(title). Cada original irá a la papelera solo cuando su copia haya llegado completa y verificada.")
        }
    }

    /// Whether a finished cross-cloud copy is good enough to let its original go: it completed, every file in it was
    /// checked against the provider's checksum, and nothing in it was skipped over a name clash. A skipped item never
    /// gets a destination name; one that was copied always does.
    static func copyAllowsRemovingSource(_ job: Transfer) -> Bool {
        job.state == .completed && job.direction == .transfer && job.unverifiedFiles == 0
            && !job.completedPaths.isEmpty && job.completedPaths.allSatisfy { job.names[$0] != nil }
    }

    /// Called for every finished transfer; acts only on the copies of a cross-cloud move.
    func finishPaneMove(_ job: Transfer) {
        guard let move = paneTransfers.pending.removeValue(forKey: job.id) else { return }
        guard Self.copyAllowsRemovingSource(job) else {
            error = L("«\(move.file.name)» se ha copiado a \(move.targetTitle), pero no todo pudo verificarse o algo se omitió. El original se queda donde estaba.")
            return
        }
        guard let source = accounts.first(where: { $0.id == move.sourceAccountID }) else {
            error = L("«\(move.file.name)» se ha copiado a \(move.targetTitle), pero su cuenta de origen ya no está conectada. El original se queda donde estaba.")
            return
        }
        Task {
            do {
                try await client(source).trash(file: move.file)
                spotlight.forget(accountID: source.id, fileID: move.file.id)
                favorites.removeAll { $0.accountID == source.id && ($0.file.id == move.file.id || $0.path.contains { $0.id == move.file.id }) }
                try? LocalStore.save(favorites, to: favoritesURL)
                reloadVisible(accountID: source.id, fresh: true)
            } catch {
                self.error = L("«\(move.file.name)» se ha copiado a \(move.targetTitle), pero el original no se pudo quitar: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Dragging between panes

    /// What a row hands over when it is dragged: a token that names the drag, never the files themselves. Dropped
    /// anywhere outside iCloudy it is a meaningless string; dropped on the other pane it finds the drag again.
    func paneDragProvider(for file: CloudFile, pane: Int) -> NSItemProvider {
        let tab = tab(inPane: pane)
        // Dragging a selected item takes the whole selection, as in the Finder; any other item goes alone.
        let files = tab.selection.contains(file.id) ? tab.visibleFiles.filter { tab.selection.contains($0.id) } : [file]
        let token = "icloudy-pane:" + UUID().uuidString
        paneTransfers.drag = PaneTransfers.Drag(token: token, pane: pane, files: files)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.iCloudyPaneItems.identifier, visibility: .ownProcess) { completion in
            completion(Data(token.utf8), nil); return nil
        }
        return provider
    }

    /// A drop on a pane. Within one account it moves, as the Finder does on one disk, and ⌥ copies; between accounts
    /// it copies, and ⌘ moves after asking.
    func dropOnPane(_ token: String, pane: Int, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let drag = paneTransfers.drag, drag.token == token, drag.pane != pane else { return false }
        paneTransfers.drag = nil
        let sameAccount = tab(inPane: drag.pane).accountID == tab(inPane: pane).accountID
        sendToPane(drag.files, from: drag.pane, to: pane, move: Self.dropMoves(sameAccount: sameAccount, modifiers: modifiers))
        return true
    }

    static func dropMoves(sameAccount: Bool, modifiers: NSEvent.ModifierFlags) -> Bool {
        sameAccount ? !modifiers.contains(.option) : modifiers.contains(.command)
    }
}

extension KeyEquivalent {
    /// F1…F12 as a menu shortcut. AppKit spells function keys as characters of the private-use area.
    static func function(_ number: Int) -> KeyEquivalent {
        KeyEquivalent(Character(Unicode.Scalar(UInt32(NSF1FunctionKey + number - 1)) ?? " "))
    }
}

extension UTType {
    /// Items dragged from one pane to the other. Declared in Info.plist and never offered outside the app.
    static let iCloudyPaneItems = UTType(exportedAs: "dev.icloudy.pane-items")
}
