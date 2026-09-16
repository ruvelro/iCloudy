import Foundation

/// Preferences the user can change from the settings window. Defaults live here so every reader agrees on them.
enum Prefs {
    static let menuBar = "menuBarEnabled"
    static let previewFollowsSelection = "previewFollowsSelection"
    static let previewConsentMB = "previewConsentMB"
    static let listingCache = "listingCacheEnabled"
    static let historyLimit = "historyLimit"

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
    static func int(_ key: String, default value: Int) -> Int {
        let stored = UserDefaults.standard.integer(forKey: key)
        return stored > 0 ? stored : value
    }
}

/// Everything iCloudy writes outside the Keychain, so the user can see what it takes and clear it.
/// Only iCloudy's own directories are ever touched; the user's files and the accounts are never involved.
enum Maintenance {
    enum Kind: String, CaseIterable, Identifiable {
        case previews, scratch, pasteboard, listings, localCopies, history, spotlight, demo
        var id: String { rawValue }

        var title: String {
            switch self {
            case .previews: return L("Temporales de vista previa")
            case .scratch: return L("Temporales de transferencias entre nubes")
            case .pasteboard: return L("Temporales del portapapeles")
            case .listings: return L("Caché de listados de carpetas")
            case .localCopies: return L("Registro de copias locales")
            case .history: return L("Historial de transferencias")
            case .spotlight: return L("Índice de Spotlight")
            case .demo: return L("Archivos de la demo local")
            }
        }
        var detail: String {
            switch self {
            case .previews: return L("Copias descargadas para ver archivos sin guardarlos. Se limpian solas al cerrar el visor y al arrancar.")
            case .scratch: return L("Bloques a medio camino entre dos nubes. Vaciarlos obliga a repetir las transferencias en pausa que los usaban.")
            case .pasteboard: return L("Archivos .txt creados al subir texto del portapapeles.")
            case .listings: return L("Nombres y tamaños del último listado de cada carpeta, para abrirlas al instante. No contiene contenidos.")
            case .localCopies: return L("Qué archivos de la nube tienes también en el Mac. Vaciarlo quita las marcas verdes; no borra ningún archivo.")
            case .history: return L("Transferencias completadas que se conservan tras limpiar el panel.")
            case .spotlight: return L("Nombres y rutas publicados en Spotlight. Vaciarlo los retira de la búsqueda del sistema.")
            case .demo: return L("Contenido simulado de la cuenta de demostración. Se vuelve a crear al usarla otra vez.")
            }
        }
        /// True when clearing loses something the user may want back, rather than a recreatable cache.
        var needsConfirmation: Bool { [.scratch, .history, .localCopies, .demo].contains(self) }
        /// Directories whose contents belong to this item; object-backed items keep their own file instead.
        var directory: URL? {
            let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            switch self {
            case .previews: return caches.appendingPathComponent("iCloudy/Previews-v1", isDirectory: true)
            case .scratch: return caches.appendingPathComponent("iCloudy/Transfers", isDirectory: true)
            case .pasteboard: return caches.appendingPathComponent("iCloudy/Pasteboard", isDirectory: true)
            case .listings: return LocalStore.directory.appendingPathComponent("Listings", isDirectory: true)
            case .demo: return LocalStore.directory.appendingPathComponent("Demo", isDirectory: true)
            case .localCopies, .history, .spotlight: return nil
            }
        }
        /// Single JSON file backing an in-memory index; the settings window clears those through their owner.
        var file: URL? {
            switch self {
            case .localCopies: return LocalStore.directory.appendingPathComponent("local-copies.json")
            case .history: return LocalStore.directory.appendingPathComponent("history.json")
            case .spotlight: return LocalStore.directory.appendingPathComponent("spotlight.json")
            default: return nil
            }
        }
    }

    /// Bytes on disk, following the directory recursively. Call it off the main actor: it walks the file system.
    nonisolated static func size(of kind: Kind) -> Int64 {
        if let file = kind.file { return Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        guard let directory = kind.directory else { return 0 }
        return size(ofDirectory: directory)
    }
    nonisolated static func size(ofDirectory directory: URL) -> Int64 {
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey], options: []) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// Guards every deletion: a path must sit inside iCloudy's own Application Support or Caches folder.
    nonisolated static func isOwned(_ url: URL) -> Bool {
        let roots = [LocalStore.directory, FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("iCloudy", isDirectory: true)]
        let path = url.standardizedFileURL.path
        return roots.contains { path == $0.standardizedFileURL.path || path.hasPrefix($0.standardizedFileURL.path + "/") }
    }
    /// Empties a directory-backed item. Object-backed items are cleared by their owner, which rewrites the file.
    nonisolated static func clear(_ kind: Kind) throws {
        guard let directory = kind.directory else { return }
        guard isOwned(directory) else { throw CloudError.message(L("Se rechazó limpiar una carpeta ajena a iCloudy.")) }
        for child in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            try FileManager.default.removeItem(at: child)
        }
    }
}
