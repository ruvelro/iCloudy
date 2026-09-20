import Foundation

enum FileNames {
    private static let oneDriveForbidden = CharacterSet(charactersIn: "\"*:<>?/\\|")
    private static let oneDriveReserved: Set<String> = ["CON", "PRN", "AUX", "NUL", "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", ".LOCK", "DESKTOP.INI"]
    /// Returns a user-facing problem, or nil when the provider will accept the name. OneDrive is far stricter than Drive.
    /// Reference: https://support.microsoft.com/office/invalid-file-names-and-file-types-in-onedrive-and-sharepoint
    static func problem(with name: String, for cloud: Cloud) -> String? {
        if name.isEmpty || name == "." || name == ".." { return L("Introduce un nombre válido.") }
        if name.contains("/") || name.contains("\0") { return L("El nombre no puede contener barras.") }
        // An FTP command ends at the line break, so a name carrying one would smuggle a second command to the server.
        if cloud == .ftp, name.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" }) { return L("FTP no admite saltos de línea en los nombres.") }
        // OneDrive, Box and most WebDAV servers sit on Windows-style rules; Drive and Dropbox are permissive.
        guard [.microsoft, .box, .webdav].contains(cloud) else { return nil }
        if name.unicodeScalars.contains(where: { oneDriveForbidden.contains($0) }) { return L("OneDrive no admite los caracteres \" * : < > ? / \\ | en los nombres.") }
        if name.hasPrefix(" ") || name.hasSuffix(" ") { return L("OneDrive no admite espacios al principio o al final del nombre.") }
        if name.hasSuffix(".") { return L("OneDrive no admite nombres que terminen en punto.") }
        if name.hasPrefix("~$") || name.contains("_vti_") { return L("OneDrive reserva los nombres que empiezan por ~$ o contienen _vti_.") }
        let stem = (name as NSString).deletingPathExtension.uppercased()
        if oneDriveReserved.contains(name.uppercased()) || oneDriveReserved.contains(stem) { return L("«\(name)» es un nombre reservado por OneDrive.") }
        if name.count > 255 { return L("OneDrive limita los nombres a 255 caracteres.") }
        return nil
    }
    static func safe(_ name: String) -> String {
        let result = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\0", with: "_")
        return result.isEmpty || result == "." || result == ".." ? "archivo" : result
    }
    static func available(in folder: URL, name: String) -> URL {
        let original = folder.appendingPathComponent(safe(name))
        var candidate = original
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let ext = original.pathExtension
            let stem = original.deletingPathExtension().lastPathComponent
            candidate = folder.appendingPathComponent("\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)"))
            number += 1
        }
        return candidate
    }
}
