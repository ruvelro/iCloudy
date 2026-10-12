import Foundation

/// Renaming several items at once, the three ways the Finder offers: replace a piece of text, add text before or after
/// the name, or give them all one name with a number. The extension is never touched.
struct BatchRename: Equatable {
    enum Mode: String, CaseIterable, Identifiable {
        case replace, add, format
        var id: String { rawValue }
        var title: String {
            switch self {
            case .replace: return L("Reemplazar texto")
            case .add: return L("Añadir texto")
            case .format: return L("Numerar")
            }
        }
    }
    enum Position: String, CaseIterable, Identifiable {
        case before, after
        var id: String { rawValue }
        var title: String { self == .before ? L("Antes del nombre") : L("Después del nombre") }
    }

    var mode = Mode.replace
    var find = ""
    var replacement = ""
    var ignoresCase = true
    var text = ""
    var position = Position.after
    var base = ""
    var start = 1

    /// The new name of each item, in the order given.
    func names(for files: [CloudFile]) -> [String] {
        let digits = String(start + max(files.count - 1, 0)).count
        return files.enumerated().map { index, file in
            let (stem, ext) = Self.split(file)
            let renamed: String
            switch mode {
            case .replace:
                renamed = find.isEmpty ? stem : stem.replacingOccurrences(of: find, with: replacement, options: ignoresCase ? [.caseInsensitive] : [])
            case .add:
                renamed = position == .before ? text + stem : stem + text
            case .format:
                let number = String(start + index)
                let padded = String(repeating: "0", count: max(0, digits - number.count)) + number
                let name = base.trimmingCharacters(in: .whitespaces)
                renamed = name.isEmpty ? padded : name + " " + padded
            }
            return ext.isEmpty ? renamed : renamed + "." + ext
        }
    }

    /// A folder keeps all of its name: "Fotos 2024.03" is not a file with an extension.
    static func split(_ file: CloudFile) -> (stem: String, ext: String) {
        let ext = (file.name as NSString).pathExtension
        guard !file.isFolder, !ext.isEmpty, ext.count <= 8, file.name.count > ext.count + 1 else { return (file.name, "") }
        return (String(file.name.dropLast(ext.count + 1)), ext)
    }

    /// Why these names cannot be applied in this folder, or nil. `siblings` is the whole folder as listed.
    static func problem(files: [CloudFile], names: [String], siblings: [CloudFile], cloud: Cloud) -> String? {
        for name in names {
            if let problem = FileNames.problem(with: name.trimmingCharacters(in: .whitespacesAndNewlines), for: cloud) { return problem }
        }
        var seen: Set<String> = []
        for name in names where !seen.insert(name.lowercased()).inserted {
            return L("Dos elementos acabarían llamándose «\(name)».")
        }
        let batch = Set(files.map(\.id))
        for name in names {
            if let other = siblings.first(where: { !batch.contains($0.id) && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                return L("En esta carpeta ya existe «\(other.name)».")
            }
        }
        return nil
    }

    /// True when some item would take a name another item of the batch still has, so renaming straight away would
    /// collide. Those are renamed through a temporary name first.
    static func needsTwoSteps(files: [CloudFile], names: [String]) -> Bool {
        let old = Set(files.map { $0.name.lowercased() })
        return zip(files, names).contains { file, name in name.lowercased() != file.name.lowercased() && old.contains(name.lowercased()) }
    }
}

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let files: [CloudFile]
    let account: Account
    let parent: String
}

extension AppModel {
    func requestBatchRename(_ files: [CloudFile]) {
        guard let account, files.count > 1, canWrite else { return }
        batchRename = BatchRenameRequest(files: files, account: account, parent: folderID)
    }

    /// Renames every item, stopping at the first refusal. Returns the items as they are named now.
    @discardableResult
    func applyBatchRename(_ files: [CloudFile], to names: [String], account: Account, api: CloudAPI) async throws -> [CloudFile] {
        var current = files
        let pairs = Array(zip(files.indices, names)).filter { files[$0.0].name != $0.1 }
        if BatchRename.needsTwoSteps(files: files, names: names) {
            for (index, _) in pairs {
                let temporary = ".icloudy-" + UUID().uuidString.prefix(8) + "-" + current[index].name
                let change = try await renameOne(current[index], to: temporary, account: account, api: api)
                current[index] = change.file(current[index])
            }
        }
        for (index, name) in pairs {
            let change = try await renameOne(current[index], to: name, account: account, api: api)
            current[index] = change.file(current[index])
        }
        return current
    }

    private func renameOne(_ file: CloudFile, to name: String, account: Account, api: CloudAPI) async throws -> RemoteIdentityChange {
        try await api.rename(file: file, name: name)
        let change = try api.identityChange(file: file, name: name)
        try applyIdentityChange(change, account: account)
        return change
    }

    /// What the sheet calls: checks the folder as it is now, renames, and leaves ⌘Z able to put every name back.
    func commitBatchRename(_ request: BatchRenameRequest, rule: BatchRename) async -> Bool {
        let names = rule.names(for: request.files)
        do {
            guard !queue.hasActive(accountID: request.account.id) else { throw CloudError.message(L("Pausa las transferencias de esta cuenta antes de renombrar sus archivos.")) }
            let api = try client(request.account)
            let siblings = try await api.list(parent: request.parent)
            if let problem = BatchRename.problem(files: request.files, names: names, siblings: siblings, cloud: request.account.cloud) {
                throw CloudError.message(problem)
            }
            let renamed = try await applyBatchRename(request.files, to: names, account: request.account, api: api)
            let originals = request.files.map(\.name), account = request.account
            registerUndoable(L("Renombrar"), account: account, undo: { model, api in
                try await model.applyBatchRename(renamed, to: originals, account: account, api: api)
            }, redo: { model, api in
                try await model.applyBatchRename(request.files, to: names, account: account, api: api)
            })
            info = L("\(request.files.count) elementos renombrados.")
            reloadAfterWrite(to: request.account)
            return true
        } catch {
            self.error = error.localizedDescription
            reloadAfterWrite(to: request.account)
            return false
        }
    }
}
