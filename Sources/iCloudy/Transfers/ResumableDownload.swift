import Foundation
import CryptoKit
import Darwin

/// A download that a provider can carry on from where it stopped, by offset, instead of starting over (SFTP today).
///
/// The queue downloads beside the destination under a name tied to the job and the item, so the next attempt of the
/// same job finds the bytes already there. The partial file carries, in an extended attribute, what it is a copy of:
/// the item's id, size and modification date as listed. A retry resumes only when the item listed now is that same
/// version and the partial is no longer than it; anything else starts again from zero, so two versions are never
/// stitched together. The whole file is still checked against the listed size (and checksum, where there is one)
/// when it is complete.
enum ResumableDownload {
    static let prefix = ".icloudy-resume-"
    private static let attribute = "dev.icloudy.download-source"

    /// The partial's name for `key` of job `job`, stable across attempts and short enough for any file system.
    static func partialName(job: UUID, key: String) -> String {
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return prefix + job.uuidString + "-" + digest + ".part"
    }
    static func isPartial(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "part" }

    /// What the partial must have been downloaded from to be continued.
    static func stamp(of file: CloudFile) -> String {
        [file.id, file.size.map(String.init) ?? "-", file.modified.map { String(Int64($0.timeIntervalSince1970)) } ?? "-"].joined(separator: "\n")
    }

    /// Where to carry on downloading `file` into `url`: the partial's size when it is a copy of this same version,
    /// zero otherwise, in which case anything already there is emptied. The stamp is written either way, before the
    /// first byte, so a partial is never left without one.
    static func prepare(_ url: URL, for file: CloudFile) throws -> Int64 {
        let expected = stamp(of: file)
        var offset: Int64 = 0
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw CloudError.message(L("El destino es un enlace simbólico. Elige otra carpeta.")) }
            // Without a size and a date the listing cannot say it is the same version, so nothing is resumed.
            if let size = file.size, file.modified != nil, read(url) == expected, info.st_size <= size {
                offset = info.st_size
            } else {
                guard truncate(url.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        } else {
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            close(fd)
        }
        write(expected, to: url)
        return offset
    }

    static func read(_ url: URL) -> String? {
        let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size < 4096 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, attribute, &buffer, size, 0, XATTR_NOFOLLOW) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }
    /// A file system without extended attributes (some SMB shares) cannot vouch for a partial: it will not be
    /// resumed, which is what the stamp is for, but the download itself goes on.
    private static func write(_ value: String, to url: URL) {
        let bytes = Array(value.utf8)
        _ = setxattr(url.path, attribute, bytes, bytes.count, 0, XATTR_NOFOLLOW)
    }

    /// Removes every partial a cancelled job left in `folder` and below. Best effort and bounded: a job's partials
    /// are only ever where its items were going.
    static func removePartials(job: UUID, under folder: URL, limit: Int = 100_000) {
        let marker = prefix + job.uuidString + "-"
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants]) else { return }
        var seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > limit { break }
            if url.lastPathComponent.hasPrefix(marker) { try? FileManager.default.removeItem(at: url) }
        }
    }
}
