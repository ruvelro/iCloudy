import Foundation

/// One blob of a listing, as Azure describes it.
struct AzureBlob: Equatable {
    let name: String
    let size: Int64
    let modified: Date?
    /// Base64, as Azure stores it, and only when the uploader set it (or the blob went up in one Put Blob).
    let md5: String?
}

/// One page of List Blobs or List Containers. `next` is the marker for the following page, nil on the last one.
struct AzureListing: Equatable {
    var prefixes: [String] = []
    var blobs: [AzureBlob] = []
    var containers: [String] = []
    var next: String?
}

/// Reading Azure's XML with the same small tree S3 uses: the answers are shallow and a few thousand entries at most.
enum AzureXML {
    static func listing(_ data: Data) throws -> AzureListing {
        guard let root = S3XMLNode.parse(data), root.name == "EnumerationResults" else {
            throw CloudError.message(L("Azure devolvió un listado que no se puede leer."))
        }
        var listing = AzureListing()
        if let containers = root.child("Containers") {
            listing.containers = containers.all("Container").compactMap { $0.value("Name") }
        }
        if let blobs = root.child("Blobs") {
            listing.prefixes = blobs.all("BlobPrefix").compactMap { $0.value("Name") }
            listing.blobs = blobs.all("Blob").compactMap { node in
                guard let name = node.value("Name") else { return nil }
                let properties = node.child("Properties")
                return AzureBlob(name: name, size: Int64(properties?.value("Content-Length") ?? "") ?? 0,
                                 modified: properties?.value("Last-Modified").flatMap(AzureSigner.rfc1123.date(from:)),
                                 md5: properties?.value("Content-MD5").flatMap { $0.isEmpty ? nil : $0 })
            }
        }
        listing.next = root.value("NextMarker").flatMap { $0.isEmpty ? nil : $0 }
        return listing
    }

    /// The code and message of an `<Error>` body.
    static func error(_ data: Data) -> (code: String, message: String?)? {
        guard let root = S3XMLNode.parse(data), root.name == "Error", let code = root.value("Code") else { return nil }
        return (code, root.value("Message")?.components(separatedBy: "\n").first)
    }

    static func blockList(_ ids: [String]) -> Data {
        var xml = #"<?xml version="1.0" encoding="utf-8"?><BlockList>"#
        for id in ids { xml += "<Latest>" + id + "</Latest>" }
        return Data((xml + "</BlockList>").utf8)
    }

    /// A Base64 MD5, as Azure lists it, in the hexadecimal notation the rest of iCloudy compares.
    static func hexMD5(_ base64: String?) -> String? {
        guard let base64, let data = Data(base64Encoded: base64), data.count == 16 else { return nil }
        return data.map { String(format: "%02x", $0) }.joined()
    }
}
