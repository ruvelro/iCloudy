import Foundation

/// One remote version of a file, as the provider keeps it. `id` is the provider's own handle for it (a Drive revision,
/// a Graph version, a Dropbox `rev`, a Box file version, a Nextcloud timestamp) and means nothing elsewhere.
struct FileVersion: Identifiable, Hashable {
    let id: String
    let modified: Date?
    let size: Int64?
    /// Who saved it, when the provider says. Dropbox only hands out an account id, which is not worth showing.
    var author: String? = nil
    /// The version the file is today. It is downloaded like the file itself and cannot be restored or deleted.
    var isCurrent = false
    /// Checksum of this version's bytes, when the provider lists one; a download of it is checked against it.
    var checksum: ContentHash? = nil
    /// A name the person gave the version (Nextcloud), or nil.
    var label: String? = nil
    /// Drive keeps a pinned revision for good instead of purging it after 30 days or 100 newer ones.
    var keepForever = false

    /// "2026-09-12 10.31", the stamp that goes into the name of a downloaded version. Dots rather than colons,
    /// because the Finder shows a colon in a name as a slash.
    var stamp: String {
        guard let modified else { return id }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return formatter.string(from: modified)
    }
}

/// A past version handed to the code that downloads a `CloudFile`: the preview, the transfer queue and "Guardar
/// copia" all take one, and rewriting each of them for versions would duplicate the checks they already make.
///
/// The version travels inside the item's id, after a separator no provider id contains, so a queued download that
/// survives a restart still knows which version it was after. That id matches nothing the listing shows, which is
/// also what keeps the local-copy badge of the current file from being set by a download of an old one.
enum VersionedFile {
    static let separator = "\u{1F}version:"

    /// The item to preview or download for `version`: named "nombre (versión 2026-09-12 10.31).ext" and carrying the
    /// version's own size and checksum, which is what the download is checked against.
    static func make(_ file: CloudFile, version: FileVersion) -> CloudFile {
        CloudFile(id: file.id + separator + version.id, name: name(file.name, version: version, document: file.isGoogleDocument),
                  mime: file.mime, size: version.size, modified: version.modified, webURL: nil, isFolder: false, checksum: version.checksum)
    }

    /// The file and version a synthetic item stands for, or nil for an ordinary item.
    static func reference(_ file: CloudFile) -> (file: CloudFile, versionID: String)? {
        guard let range = file.id.range(of: separator, options: .backwards) else { return nil }
        let original = String(file.id[..<range.lowerBound]), version = String(file.id[range.upperBound...])
        guard !original.isEmpty, !version.isEmpty else { return nil }
        return (CloudFile(id: original, name: file.name, mime: file.mime, size: file.size, modified: file.modified, webURL: nil,
                          isFolder: false, checksum: file.checksum), version)
    }

    /// The suffix goes before the extension so the copy still opens with the same application. A Google document has
    /// no extension of its own: the export adds one after the whole name.
    static func name(_ name: String, version: FileVersion, document: Bool = false) -> String {
        let ext = document ? "" : (name as NSString).pathExtension
        let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        return L("\(base) (versión \(version.stamp))") + (ext.isEmpty ? "" : "." + ext)
    }
}
