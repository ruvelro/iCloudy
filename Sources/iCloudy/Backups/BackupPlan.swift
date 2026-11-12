import Foundation

/// When a scheduled copy runs by itself. iCloudy has to be open for any of it: there is no helper running behind
/// its back, which is the same promise the rest of the app makes.
struct BackupSchedule: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case manual, hourly, daily, weekly }
    var kind: Kind = .daily
    /// Hours between runs, for `hourly`.
    var every = 6
    /// Minutes after midnight, for `daily` and `weekly`.
    var minutes = 3 * 60
    /// 1 is Sunday, as `Calendar` counts, for `weekly`.
    var weekday = 1

    /// Whether a run is owed: the schedule's most recent moment has passed and nothing has run since.
    func isDue(lastRun: Date?, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch kind {
        case .manual: return false
        case .hourly:
            guard let lastRun else { return true }
            return now.timeIntervalSince(lastRun) >= Double(max(1, every)) * 3600
        case .daily, .weekly:
            guard let previous = previous(before: now, calendar: calendar) else { return false }
            // A plan made a minute ago does not owe yesterday's run.
            guard let lastRun else { return true }
            return lastRun < previous
        }
    }
    /// The last moment the schedule named, at or before `now`.
    func previous(before now: Date, calendar: Calendar = .current) -> Date? {
        var parts = DateComponents(hour: (minutes / 60) % 24, minute: minutes % 60, second: 0)
        if kind == .weekly { parts.weekday = min(max(weekday, 1), 7) }
        guard kind == .daily || kind == .weekly else { return nil }
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: parts, matchingPolicy: .nextTime, direction: .backward)
    }
    var summary: String {
        let time = String(format: "%02d:%02d", (minutes / 60) % 24, minutes % 60)
        switch kind {
        case .manual: return L("Solo a mano")
        case .hourly: return every == 1 ? L("Cada hora") : L("Cada \(every) horas")
        case .daily: return L("Cada día a las \(time)")
        case .weekly:
            let names = Calendar.current.weekdaySymbols
            return L("Cada \(names[min(max(weekday, 1), 7) - 1]) a las \(time)")
        }
    }
}

extension BackupSchedule {
    enum CodingKeys: String, CodingKey { case kind, every, minutes, weekday }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // A kind written by a newer version is read as manual: the plan is kept and nothing runs unasked.
        kind = (try? values.decodeIfPresent(String.self, forKey: .kind)).flatMap { $0.flatMap(Kind.init(rawValue:)) } ?? .manual
        every = try values.decodeIfPresent(Int.self, forKey: .every) ?? 6
        minutes = try values.decodeIfPresent(Int.self, forKey: .minutes) ?? 180
        weekday = try values.decodeIfPresent(Int.self, forKey: .weekday) ?? 1
    }
}

/// A folder of one account copied to a folder of another, again and again.
///
/// Each run brings the destination up to date with the source: what is new or changed travels, what did not change
/// is not even downloaded. What the run replaces or removes at the destination can be kept instead, in a dated
/// folder of "Versiones anteriores", so the copy is also a history of what the source used to hold.
struct BackupPlan: Identifiable, Codable, Equatable {
    var id = UUID()
    var sourceAccountID: String
    var sourceFolderID: String
    /// "cuenta / Carpeta", for display.
    var sourceName: String
    var targetAccountID: String
    var targetFolderID: String
    var targetName: String
    var schedule = BackupSchedule()
    /// What a run replaces or removes at the destination is moved to a dated folder instead of being lost.
    var keepsVersions = true
    /// What was copied by this plan and is no longer in the source is taken out of the destination too. Off, the
    /// destination only ever grows.
    var removesDeleted = false
    /// Dated folders of earlier versions older than this are sent to the bin. Nil keeps them all.
    var retentionDays: Int? = 30
    var paused = false
    /// The source as it was when each path was last copied: relative path → signature. A path that is here and
    /// whose signature still matches has nothing new to send.
    var baseline: [String: String] = [:]
    /// What the running job will leave the baseline as.
    var pending: [String: String]?
    var activeTransferID: UUID?
    var lastRun: Date?
    var lastSummary: String?
    var lastError: String?

    static let versionsFolder = "Versiones anteriores (iCloudy)"
    var title: String { sourceName.split(separator: "/").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? sourceName }
}

extension BackupPlan {
    enum CodingKeys: String, CodingKey {
        case id, sourceAccountID, sourceFolderID, sourceName, targetAccountID, targetFolderID, targetName, schedule
        case keepsVersions, removesDeleted, retentionDays, paused, baseline, pending, activeTransferID, lastRun, lastSummary, lastError
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        sourceAccountID = try values.decode(String.self, forKey: .sourceAccountID)
        sourceFolderID = try values.decode(String.self, forKey: .sourceFolderID)
        sourceName = try values.decodeIfPresent(String.self, forKey: .sourceName) ?? ""
        targetAccountID = try values.decode(String.self, forKey: .targetAccountID)
        targetFolderID = try values.decode(String.self, forKey: .targetFolderID)
        targetName = try values.decodeIfPresent(String.self, forKey: .targetName) ?? ""
        schedule = try values.decodeIfPresent(BackupSchedule.self, forKey: .schedule) ?? BackupSchedule(kind: .manual)
        keepsVersions = try values.decodeIfPresent(Bool.self, forKey: .keepsVersions) ?? true
        removesDeleted = try values.decodeIfPresent(Bool.self, forKey: .removesDeleted) ?? false
        retentionDays = try values.decodeIfPresent(Int.self, forKey: .retentionDays)
        paused = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        baseline = try values.decodeIfPresent([String: String].self, forKey: .baseline) ?? [:]
        pending = try values.decodeIfPresent([String: String].self, forKey: .pending)
        activeTransferID = try values.decodeIfPresent(UUID.self, forKey: .activeTransferID)
        lastRun = try values.decodeIfPresent(Date.self, forKey: .lastRun)
        lastSummary = try values.decodeIfPresent(String.self, forKey: .lastSummary)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
    }
}

/// Refuses a run that would take most of the copy away. An emptied or disconnected source looks exactly like a
/// source where everything was deleted, and a backup that follows it into the void is no backup.
struct BackupRemovalRefused: LocalizedError {
    let count: Int
    var errorDescription: String? {
        L("La copia retiraría \(count) archivos del destino, la mayor parte de lo que hay. No se ha tocado nada. Si es lo que quieres, elige «Ejecutar aplicando los borrados» en el menú de la copia.")
    }
}

/// One item of either tree as a run sees it.
struct BackupNode: Equatable {
    /// Names from the top of the plan's folder down, joined with "/".
    var path: String
    var file: CloudFile
    /// The item's key in the transfer job that walks the source: "./id/id".
    var key: String = ""
}

/// Pure planning: given both trees and what was copied before, what a run has to do.
enum BackupPlanner {
    struct Outcome: Equatable {
        /// Keys of the transfer tree with nothing to send below them; the job skips them without a request.
        var completed: Set<String> = []
        var names: [String: String] = ["."  : ""]
        /// Source folders that already exist at the destination, by key, with the folder they go into.
        var folders: [String: String] = [:]
        /// Files whose destination copy is overwritten in place, by key.
        var replacements: [String: String] = [:]
        /// Destination items taken out of the way before the copy: replaced ones when versions are kept, and what
        /// the source no longer has.
        var retire: [BackupNode] = []
        var copies = 0, replaces = 0, removals = 0, skipped = 0
        var bytes: Int64 = 0
        /// What the baseline becomes once the job has completed.
        var signatures: [String: String] = [:]
        var nothingToDo: Bool { copies + replaces + removals == 0 }
        var summary: String {
            var parts: [String] = []
            if copies > 0 { parts.append(L("\(copies) nuevos")) }
            if replaces > 0 { parts.append(L("\(replaces) actualizados")) }
            if removals > 0 { parts.append(L("\(removals) retirados")) }
            if skipped > 0 { parts.append(L("\(skipped) omitidos")) }
            return parts.isEmpty ? L("sin cambios") : parts.joined(separator: ", ")
        }
    }

    static let massRemovalMinimum = 10

    /// The name an item of the source takes at the destination: its own, with the extension of the Office or PDF
    /// file a Google document leaves Drive as.
    static func targetName(_ file: CloudFile) -> String {
        guard !file.isFolder, file.isGoogleDocument, let export = file.crossCloudExport else { return file.name }
        return file.name + "." + export.ext
    }

    /// `source` and `target` list every item below the plan's two folders, parents before children. `target` only
    /// needs the folders that have a counterpart in the source; anything else there is not this plan's business.
    static func plan(source: [BackupNode], target: [BackupNode], plan: BackupPlan, targetCloud: Cloud, canMove: Bool,
                     allowMassRemoval: Bool = false) throws -> Outcome {
        var outcome = Outcome()
        outcome.names["."] = plan.title
        outcome.folders["."] = plan.targetFolderID
        let keepsVersions = plan.keepsVersions && canMove
        // The destination by lower-cased path: most providers would not let two names differ only in case anyway.
        var there: [String: BackupNode] = [:]
        for node in target where there[node.path.lowercased()] == nil { there[node.path.lowercased()] = node }
        var taken: Set<String> = []
        var blocked: [String] = []
        var changedFolders: Set<String> = []
        var folderKeys: [String: String] = [:]
        func markChanged(_ path: String) {
            var parent = path
            while let slash = parent.lastIndex(of: "/") { parent = String(parent[..<slash]); changedFolders.insert(parent) }
            changedFolders.insert("")
        }
        for node in source {
            let parentPath = node.path.split(separator: "/").dropLast().joined(separator: "/")
            if blocked.contains(where: { node.path.hasPrefix($0 + "/") }) { outcome.completed.insert(node.key); continue }
            let name = targetName(node.file)
            let destinationPath = parentPath.isEmpty ? name : parentPath + "/" + name
            // The second of two items with one name (Drive allows it) would overwrite the first: it stays behind.
            guard taken.insert(destinationPath.lowercased()).inserted,
                  FileNames.problem(with: name, for: targetCloud) == nil,
                  !(node.file.isGoogleDocument && node.file.crossCloudExport == nil) else {
                outcome.skipped += 1; outcome.completed.insert(node.key)
                if node.file.isFolder { blocked.append(node.path) }
                continue
            }
            let existing = there[destinationPath.lowercased()]
            outcome.names[node.key] = name
            if node.file.isFolder {
                folderKeys[node.path] = node.key
                if let existing {
                    guard existing.file.isFolder else {
                        // A file sits where the folder would go. Nothing of ours is put on top of it.
                        outcome.skipped += 1; outcome.completed.insert(node.key); blocked.append(node.path); continue
                    }
                    outcome.folders[node.key] = existing.file.id
                } else { markChanged(node.path + "/x") }
                continue
            }
            let signature = SyncEntry.signature(node.file)
            outcome.signatures[node.path] = signature
            guard let existing else {
                outcome.copies += 1; outcome.bytes += node.file.size ?? 0; markChanged(node.path); continue
            }
            guard !existing.file.isFolder else { outcome.skipped += 1; outcome.completed.insert(node.key); outcome.signatures[node.path] = nil; continue }
            // Unchanged: the source is what it was when it was copied, and the copy is still the size it had. A
            // Google document has no size to compare, so only its date speaks for it.
            let sameSize = node.file.isGoogleDocument || node.file.size == nil || existing.file.size == nil || node.file.size == existing.file.size
            if plan.baseline[node.path] == signature, sameSize { outcome.completed.insert(node.key); continue }
            outcome.replaces += 1; outcome.bytes += node.file.size ?? 0; markChanged(node.path)
            if keepsVersions { outcome.retire.append(existing) } else { outcome.replacements[node.key] = existing.file.id }
        }
        // A folder with nothing to send anywhere below it is skipped whole, without being listed again.
        for (path, key) in folderKeys where !changedFolders.contains(path) && outcome.folders[key] != nil { outcome.completed.insert(key) }
        // What this plan copied before and the source no longer has. Things at the destination that the plan never
        // put there are somebody else's, and stay.
        if plan.removesDeleted {
            let present = Set(source.map { node -> String in
                let parent = node.path.split(separator: "/").dropLast().joined(separator: "/")
                let name = targetName(node.file)
                return (parent.isEmpty ? name : parent + "/" + name).lowercased()
            })
            var gone: [BackupNode] = []
            for path in plan.baseline.keys {
                guard !source.contains(where: { $0.path == path }) else { continue }
                // The baseline is keyed by the source's name; a Google document sits at the destination with its
                // export extension, which only the destination listing knows now.
                let candidates = target.filter { !$0.file.isFolder && ($0.path == path || $0.path.hasPrefix(path + ".")) && !present.contains($0.path.lowercased()) }
                gone += candidates.prefix(1)
            }
            let total = plan.baseline.count
            if !allowMassRemoval, gone.count >= massRemovalMinimum, gone.count * 2 > total {
                throw BackupRemovalRefused(count: gone.count)
            }
            outcome.removals = gone.count
            outcome.retire += gone
        }
        return outcome
    }
}
