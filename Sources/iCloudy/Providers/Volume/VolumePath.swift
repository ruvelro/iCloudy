import Foundation
import Darwin

/// Pins each directory with openat/O_NOFOLLOW. A later symlink substitution cannot redirect reads or writes.
final class VolumePath: @unchecked Sendable {
    let parent: Int32
    let name: String
    let url: URL
    init(root: URL, url: URL) throws {
        let base = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path == base || path.hasPrefix(base + "/") else {
            throw CloudError.message(L("Ese elemento está fuera de la carpeta conectada."))
        }
        self.url = url
        let parts = path == base ? [] : String(path.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
        // Resolve system aliases above the selected root (e.g. /var), never a substituted root itself.
        let rootURL = root.standardizedFileURL
        let physicalRoot = rootURL.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(rootURL.lastPathComponent)
        var descriptor = open(physicalRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Self.error() }
        do {
            for component in parts.dropLast() {
                let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.error() }
                close(descriptor); descriptor = next
            }
            name = parts.last ?? "."
            var info = stat()
            let status = fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW)
            guard status == 0 || errno == ENOENT else { throw Self.error() }
            guard status != 0 || info.st_mode & S_IFMT != S_IFLNK else {
                throw CloudError.message(L("No se admiten enlaces simbólicos."))
            }
            parent = descriptor
        } catch { close(descriptor); throw error }
    }
    deinit { close(parent) }
    func openFile(_ flags: Int32, mode: mode_t = 0o600) throws -> FileHandle {
        let fd = openat(parent, name, flags | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Self.error() }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
    func directory() throws -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error() }
        return fd
    }
    /// Copies recursively using pinned directory descriptors. Symlinks, including intermediate substitutions,
    /// are refused instead of resolving into another account or outside the selected root.
    static func copy(sourceParent: Int32, source: String, targetParent: Int32, target: String, depth: Int = 0) throws {
        try Task.checkCancellation()
        guard depth < 128 else { throw POSIXError(.ELOOP) }
        var info = stat()
        guard fstatat(sourceParent, source, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw error() }
        let kind = info.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG else { throw CloudError.message(L("No se admiten enlaces simbólicos.")) }
        let input = openat(sourceParent, source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | (kind == S_IFDIR ? O_DIRECTORY : 0))
        guard input >= 0 else { throw error() }
        defer { close(input) }
        if kind == S_IFDIR {
            guard mkdirat(targetParent, target, 0o700) == 0 else { throw error() }
            let output = openat(targetParent, target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard output >= 0 else { throw error() }
            defer { close(output) }
            for name in try names(input) {
                try copy(sourceParent: input, source: name, targetParent: output, target: name, depth: depth + 1)
            }
        } else {
            let output = openat(targetParent, target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw error() }
            defer { close(output) }
            guard fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
                let failure = error(); unlinkat(targetParent, target, 0); throw failure
            }
        }
    }
    static func file(parent: Int32, name: String, url: URL) throws -> CloudFile {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw error() }
        let folder = info.st_mode & S_IFMT == S_IFDIR
        return CloudFile(id: url.standardizedFileURL.path, name: name,
                         mime: folder ? "application/vnd.google-apps.folder" : CloudSession.mime(forName: name),
                         size: folder ? nil : info.st_size,
                         modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9),
                         webURL: nil, isFolder: folder)
    }
    static func error() -> Error {
        if errno == EEXIST { return CloudError.message(L("Ya existe un elemento con ese nombre en el destino.")) }
        if errno == ELOOP || errno == ENOTDIR { return CloudError.message(L("No se admiten enlaces simbólicos.")) }
        return POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    static func names(_ fd: Int32, limit: Int = Int.max) throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw error() }
        guard let directory = fdopendir(duplicate) else { close(duplicate); throw error() }
        defer { closedir(directory) }
        var result: [String] = []
        while result.count < limit, let entry = readdir(directory) {
            try Task.checkCancellation()
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
        }
        return result
    }
}
