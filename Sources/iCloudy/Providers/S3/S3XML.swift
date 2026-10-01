import Foundation

/// A tiny element tree built with `XMLParser`. S3 answers are small (a thousand entries at most per page) and shallow,
/// so a tree is simpler to read than a streaming delegate per response type.
final class S3XMLNode {
    let name: String
    var text = ""
    var children: [S3XMLNode] = []
    init(name: String) { self.name = name }

    func child(_ name: String) -> S3XMLNode? { children.first { $0.name == name } }
    func all(_ name: String) -> [S3XMLNode] { children.filter { $0.name == name } }
    /// Text of the first child called `name`, trimmed; nil when there is no such child.
    func value(_ name: String) -> String? { child(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) } }

    static func parse(_ data: Data) -> S3XMLNode? {
        guard !data.isEmpty else { return nil }
        let builder = S3XMLBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = builder
        guard parser.parse() else { return nil }
        return builder.root
    }
}

private final class S3XMLBuilder: NSObject, XMLParserDelegate {
    var root: S3XMLNode?
    private var stack: [S3XMLNode] = []
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        let node = S3XMLNode(name: element)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) { stack.removeLast() }
}

/// One object of a listing, as S3 describes it.
struct S3Object: Equatable {
    let key: String
    let size: Int64
    let modified: Date?
    /// Without the quotes S3 wraps it in.
    let etag: String?
}

/// One page of ListObjectsV2.
struct S3Listing: Equatable {
    var prefixes: [String] = []
    var objects: [S3Object] = []
    /// Continuation token for the next page, present only while the listing is truncated.
    var next: String?
}

struct S3Bucket: Equatable {
    let name: String
    /// Only newer servers say where each bucket lives; the others leave it to the first request.
    let region: String?
}

struct S3Part: Equatable {
    let number: Int
    let etag: String
    let size: Int64
}

/// The `<Error>` document S3 answers a refusal with, and sometimes a 200 too.
struct S3ErrorBody: Equatable {
    let code: String
    let message: String?
    /// The bucket's real region, when the request went to the wrong one.
    let region: String?
    let serverTime: Date?
}

enum S3XML {
    /// ETags arrive quoted, and some servers send `&quot;` that the parser has already turned into quotes.
    nonisolated static func etag(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" \n\t"))
        return trimmed.isEmpty ? nil : trimmed
    }

    static func listing(_ data: Data) throws -> S3Listing {
        guard let root = S3XMLNode.parse(data), root.name == "ListBucketResult" else {
            throw CloudError.message(L("S3 respondió algo que no es un listado. Comprueba la dirección del servicio."))
        }
        var listing = S3Listing()
        listing.prefixes = root.all("CommonPrefixes").compactMap { $0.value("Prefix") }
        listing.objects = root.all("Contents").compactMap { node in
            guard let key = node.value("Key") else { return nil }
            return S3Object(key: key, size: node.value("Size").flatMap(Int64.init) ?? 0,
                            modified: CloudSession.date(node.value("LastModified")), etag: etag(node.value("ETag")))
        }
        if root.value("IsTruncated") == "true" { listing.next = root.value("NextContinuationToken") }
        return listing
    }

    static func buckets(_ data: Data) throws -> (buckets: [S3Bucket], next: String?) {
        guard let root = S3XMLNode.parse(data), root.name == "ListAllMyBucketsResult" else {
            throw CloudError.message(L("S3 respondió algo que no es una lista de buckets. Comprueba la dirección del servicio."))
        }
        let buckets = (root.child("Buckets")?.all("Bucket") ?? []).compactMap { node in
            node.value("Name").map { S3Bucket(name: $0, region: node.value("BucketRegion")) }
        }
        return (buckets, root.value("ContinuationToken").flatMap { $0.isEmpty ? nil : $0 })
    }

    static func uploadID(_ data: Data) throws -> String {
        guard let root = S3XMLNode.parse(data), let id = root.value("UploadId"), !id.isEmpty else {
            throw CloudError.message(L("No se pudo iniciar la sesión de subida."))
        }
        return id
    }

    static func parts(_ data: Data) throws -> (parts: [S3Part], next: String?) {
        guard let root = S3XMLNode.parse(data), root.name == "ListPartsResult" else {
            throw CloudError.message(L("S3 no devolvió las partes ya subidas."))
        }
        let parts = root.all("Part").compactMap { node -> S3Part? in
            guard let number = node.value("PartNumber").flatMap(Int.init), let tag = etag(node.value("ETag")) else { return nil }
            return S3Part(number: number, etag: tag, size: node.value("Size").flatMap(Int64.init) ?? 0)
        }
        let next = root.value("IsTruncated") == "true" ? root.value("NextPartNumberMarker") : nil
        return (parts, next)
    }

    /// The ETag of a finished multipart upload or of a copy (`CopyObjectResult`, `CopyPartResult`).
    static func resultETag(_ data: Data) -> String? { S3XMLNode.parse(data)?.value("ETag").flatMap(etag) }

    static func error(_ data: Data) -> S3ErrorBody? {
        guard let root = S3XMLNode.parse(data), root.name == "Error", let code = root.value("Code") else { return nil }
        return S3ErrorBody(code: code, message: root.value("Message"), region: root.value("Region"),
                           serverTime: CloudSession.date(root.value("ServerTime")))
    }

    /// The keys DeleteObjects could not remove, with the reason it gave for the first one.
    static func deleteFailures(_ data: Data) -> [S3ErrorBody] {
        guard let root = S3XMLNode.parse(data) else { return [] }
        return root.all("Error").compactMap { node in
            node.value("Code").map { S3ErrorBody(code: $0, message: (node.value("Key").map { "«\($0)»: " } ?? "") + (node.value("Message") ?? ""), region: nil, serverTime: nil) }
        }
    }

    nonisolated static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    static func completeBody(_ etags: [String]) -> Data {
        let parts = etags.enumerated().map { index, tag in
            "<Part><PartNumber>\(index + 1)</PartNumber><ETag>\"\(escape(tag))\"</ETag></Part>"
        }.joined()
        return Data(("<CompleteMultipartUpload xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\">" + parts + "</CompleteMultipartUpload>").utf8)
    }

    static func deleteBody(_ keys: [String]) -> Data {
        let objects = keys.map { "<Object><Key>\(escape($0))</Key></Object>" }.joined()
        return Data(("<Delete xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Quiet>true</Quiet>" + objects + "</Delete>").utf8)
    }
}

/// Turns what S3 says into something a person can act on. The codes are the same across AWS and the compatible
/// services; the advice is what usually fixes each one.
enum S3Failure {
    /// Codes that mean the request may simply be repeated after a pause.
    static let transient: Set<String> = ["SlowDown", "ServiceUnavailable", "InternalError", "RequestTimeout", "OperationAborted"]
    /// Codes that say the bucket lives in another region than the one the request was signed for.
    static let wrongRegion: Set<String> = ["PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException", "TemporaryRedirect"]

    static func message(status: Int, body: S3ErrorBody?, bucket: String?) -> String {
        let code = body?.code ?? ""
        let detail = body?.message.flatMap { $0.isEmpty ? nil : $0 }
        let name = bucket ?? ""
        switch code {
        case "AccessDenied", "AllAccessDisabled", "AccountProblem":
            return L("S3 ha denegado el acceso. Comprueba que la clave tiene permiso para esta operación en este bucket.")
        case "InvalidAccessKeyId":
            return L("El servicio no reconoce el ID de clave de acceso. Puede que se haya borrado o desactivado: crea otra y vuelve a conectar la cuenta.")
        case "SignatureDoesNotMatch":
            return L("La firma de la petición no coincide. Revisa la clave secreta; si es correcta, comprueba que la fecha y la hora del Mac sean las buenas, porque S3 solo admite unos minutos de desfase.")
        case "RequestTimeTooSkewed":
            return L("La hora de este Mac difiere demasiado de la del servidor. Activa «Ajustar fecha y hora automáticamente» en Ajustes del Sistema y vuelve a intentarlo.")
        case "NoSuchBucket":
            return name.isEmpty ? L("El bucket no existe o pertenece a otra cuenta.") : L("El bucket «\(name)» no existe o pertenece a otra cuenta.")
        case "NoSuchKey":
            return L("El objeto ya no existe en el bucket.")
        case "NoSuchUpload":
            return L("La subida por partes ya no existe en el servidor: se canceló o caducó.")
        case "PermanentRedirect", "AuthorizationHeaderMalformed", "IllegalLocationConstraintException", "TemporaryRedirect":
            if let region = body?.region { return L("El bucket está en otra región (\(region)). Vuelve a conectar la cuenta eligiendo esa región.") }
            return L("El bucket está en otra región. Vuelve a conectar la cuenta eligiendo la región correcta.")
        case "SlowDown", "ServiceUnavailable":
            return L("S3 pide reducir el ritmo de peticiones. Inténtalo de nuevo dentro de un momento.")
        case "InternalError":
            return L("El servicio S3 tuvo un error interno. Inténtalo de nuevo más tarde.")
        case "BadDigest", "InvalidDigest", "XAmzContentSHA256Mismatch":
            return L("El contenido llegó al servidor distinto de como salió del Mac y se ha rechazado. Vuelve a intentarlo.")
        case "EntityTooLarge":
            return L("El archivo supera el tamaño máximo que admite el servicio.")
        case "EntityTooSmall":
            return L("Una de las partes de la subida es más pequeña de lo que admite el servicio.")
        case "InvalidPart", "InvalidPartOrder":
            return L("El servidor no reconoce alguna de las partes subidas. Cancela la subida y vuelve a empezar.")
        case "KeyTooLongError":
            return L("La ruta completa del objeto supera los 1024 bytes que admite S3. Usa nombres o carpetas más cortos.")
        case "InvalidObjectState":
            return L("El objeto está archivado (por ejemplo en Glacier) y hay que restaurarlo antes de leerlo.")
        case "NotImplemented":
            return L("Este servicio compatible con S3 no admite la operación solicitada.")
        case "PreconditionFailed":
            return L("El objeto cambió en el servidor durante la operación. Vuelve a intentarlo.")
        case "InvalidRange":
            return L("El servidor rechazó el rango pedido del objeto.")
        case "BucketNotEmpty":
            return L("El bucket no está vacío.")
        case "InvalidBucketName":
            return L("El nombre del bucket no es válido.")
        case "QuotaExceeded", "StorageQuotaExceeded", "XMinioStorageFull":
            return L("No queda espacio en el servicio para guardar más datos.")
        case "":
            break
        default:
            return L("S3 respondió \(code): \(detail ?? L("sin más detalle")).")
        }
        // A HEAD, or a gateway in front of the service, answers without an `<Error>` body.
        switch status {
        case 301, 307: return L("El bucket está en otra región. Vuelve a conectar la cuenta eligiendo la región correcta.")
        case 403: return L("S3 ha denegado el acceso. Comprueba que la clave tiene permiso para esta operación en este bucket.")
        case 404: return L("El objeto ya no existe en el bucket.")
        case 412: return L("El objeto cambió en el servidor durante la operación. Vuelve a intentarlo.")
        case 503: return L("S3 pide reducir el ritmo de peticiones. Inténtalo de nuevo dentro de un momento.")
        default: return L("El servicio devolvió HTTP \(status).") + " " + L("Inténtalo de nuevo más tarde.")
        }
    }

    static func error(_ response: HTTPURLResponse, data: Data, bucket: String?) -> ServiceError {
        let body = S3XML.error(data)
        return ServiceError(status: response.statusCode, detail: message(status: response.statusCode, body: body, bucket: bucket),
                            code: body?.code, retryAfter: Double(response.value(forHTTPHeaderField: "Retry-After") ?? ""))
    }
}
