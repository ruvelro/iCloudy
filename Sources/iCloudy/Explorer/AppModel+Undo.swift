import AppKit

/// ⌘Z for what is cheap to take back on the provider: renaming, moving inside one account and, where the provider can
/// bring an item back by its id, sending it to the bin.
///
/// Each step runs asynchronously, against the provider. `UndoManager` files whatever is registered while it is
/// undoing as redo, so a step registers its inverse synchronously as it starts and only then goes to the network. A
/// step that fails clears the history: what is left in it describes a state that no longer exists.
extension AppModel {
    /// Providers whose bin gives an item back from its id alone. Dropbox needs the revision its bin lists, and the
    /// Finder's Trash is out of reach of the sandbox.
    static func undoesTrash(_ account: Account) -> Bool {
        account.isDemo || [.google, .box, .pcloud, .mega].contains(account.cloud)
    }

    func registerUndoable(_ name: String, account: Account, undo: @escaping (AppModel, CloudAPI) async throws -> Void,
                          redo: @escaping (AppModel, CloudAPI) async throws -> Void) {
        guard let manager = undoManager else { return }
        manager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.registerUndoable(name, account: account, undo: redo, redo: undo)
                Task { @MainActor in
                    do {
                        guard model.accounts.contains(where: { $0.id == account.id }) || account.isDemo else {
                            throw CloudError.message(L("La cuenta de esta acción ya no está conectada."))
                        }
                        guard !model.queue.hasActive(accountID: account.id) else {
                            throw CloudError.message(L("Pausa las transferencias de esta cuenta antes de deshacer."))
                        }
                        try await undo(model, try model.client(account))
                    } catch {
                        manager.removeAllActions(withTarget: model)
                        model.error = L("No se pudo deshacer «\(name)»: \(error.localizedDescription)")
                    }
                    model.reloadAfterWrite(to: account)
                }
            }
        }
        manager.setActionName(name)
    }

    /// After a rename that went through. Undoing renames the new item back; redoing renames the original again.
    func registerRenameUndo(_ file: CloudFile, renamed: CloudFile, account: Account) {
        registerUndoable(L("Renombrar"), account: account, undo: { model, api in
            try await model.applyRename(renamed, to: file.name, account: account, api: api)
        }, redo: { model, api in
            try await model.applyRename(file, to: renamed.name, account: account, api: api)
        })
    }

    func applyRename(_ file: CloudFile, to name: String, account: Account, api: CloudAPI) async throws {
        try await api.rename(file: file, name: name)
        try applyIdentityChange(api.identityChange(file: file, name: name), account: account)
    }

    /// After a move inside one account: each item, where it went and where it came from.
    func registerMoveUndo(_ moves: [(file: CloudFile, moved: CloudFile, from: String, to: String)], account: Account) {
        guard !moves.isEmpty else { return }
        registerUndoable(L("Mover"), account: account, undo: { model, api in
            for move in moves.reversed() { try await model.applyMove(move.moved, to: move.from, account: account, api: api) }
        }, redo: { model, api in
            for move in moves { try await model.applyMove(move.file, to: move.to, account: account, api: api) }
        })
    }

    func applyMove(_ file: CloudFile, to destination: String, account: Account, api: CloudAPI) async throws {
        try await api.move(file: file, to: destination)
        try applyIdentityChange(api.identityChange(file: file, name: file.name, destination: destination), account: account)
    }

    /// After sending items to the bin, where the provider can take them out again.
    func registerTrashUndo(_ files: [CloudFile], account: Account) {
        guard !files.isEmpty, Self.undoesTrash(account) else { return }
        registerUndoable(L("Enviar a la papelera"), account: account, undo: { _, api in
            for file in files { try await api.restore(file: file) }
        }, redo: { _, api in
            for file in files { try await api.trash(file: file) }
        })
    }
}
