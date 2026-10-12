import Foundation

/// Object versions, on buckets with versioning switched on. ListObjectVersions lists every version of the key (and the
/// keys after it, which are skipped); one is read with `versionId`, restored by copying it over the key, which keeps
/// the replaced content as one more version, and deleted for good with DELETE and its `versionId`.
///
/// A bucket without versioning lists the object once, with the version id "null": there is no history to show, and
/// the sheet says how to get one.
extension S3Provider {
    func versions(of file: CloudFile) async throws -> [FileVersion] {
        let path = try object(file.id)
        guard !path.isFolder else { throw CloudError.message(L("Las carpetas no tienen versiones. Ábrela y consulta las de cada archivo.")) }
        var found: [FileVersion] = []
        var keyMarker: String?, versionMarker: String?
        // Fifty pages of a thousand versions is far more history than anyone browses in a sheet.
        for _ in 0..<50 {
            var query: [(String, String?)] = [("versions", nil), ("prefix", path.key)]
            if let keyMarker { query.append(("key-marker", keyMarker)) }
            if let versionMarker { query.append(("version-id-marker", versionMarker)) }
            var call = S3Call(bucket: path.bucket, query: query)
            call.repeatable = true
            guard let root = S3XMLNode.parse(try await s3(call).0) else { throw CloudError.message(L("El servidor respondió algo que no es un listado de S3.")) }
            found += Self.versions(root, key: path.key)
            guard root.value("IsTruncated") == "true", let nextKey = root.value("NextKeyMarker"), nextKey == path.key else { break }
            keyMarker = nextKey; versionMarker = root.value("NextVersionIdMarker")
        }
        if found.count <= 1, found.allSatisfy({ $0.id == "null" }) {
            throw CloudError.message(L("Este bucket no guarda versiones. Activa el control de versiones en la configuración del bucket y S3 empezará a conservarlas."))
        }
        return found.sorted { a, b in
            if a.isCurrent != b.isCurrent { return a.isCurrent }
            return (a.modified ?? .distantPast) > (b.modified ?? .distantPast)
        }
    }

    /// The versions of exactly `key` in one page. Delete markers are not content and are left out.
    nonisolated static func versions(_ root: S3XMLNode, key: String) -> [FileVersion] {
        root.all("Version").filter { $0.value("Key") == key }.map { node in
            let etag = S3XML.etag(node.value("ETag"))
            return FileVersion(id: node.value("VersionId") ?? "null", modified: CloudSession.date(node.value("LastModified")),
                               size: node.value("Size").flatMap(Int64.init), isCurrent: node.value("IsLatest") == "true",
                               checksum: etag.flatMap { isPlainMD5($0) ? ContentHash(algorithm: .md5, value: $0.lowercased()) : nil })
        }
    }

    /// A presigned link to that version, read like any other download.
    func versionContentRequest(for file: CloudFile, version: String, exportMime: String?) async throws -> URLRequest {
        let path = try object(file.id)
        let location = try location(for: path.bucket)
        let url = try location.url(bucket: path.bucket, key: path.key, query: [("versionId", version)])
        guard let link = S3Signer.presign(url: url, keys: try keys(), region: location.region, date: Date().addingTimeInterval(clockOffset), expires: 3600) else {
            throw CloudError.message(L("No se pudo construir la dirección del elemento en el servidor."))
        }
        return URLRequest(url: link)
    }

    func restoreVersion(_ version: FileVersion, of file: CloudFile) async throws {
        let path = try object(file.id)
        try await copyObject(path, size: version.size ?? file.size ?? 0, to: path, versionID: version.id)
    }

    func deleteVersion(_ version: FileVersion, of file: CloudFile) async throws {
        let path = try object(file.id)
        _ = try await s3(S3Call(method: "DELETE", bucket: path.bucket, key: path.key, query: [("versionId", version.id)]))
    }
}
