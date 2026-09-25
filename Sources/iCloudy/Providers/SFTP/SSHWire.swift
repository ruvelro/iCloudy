import Foundation

/// The SSH wire encoding of RFC 4251 §5: big-endian integers, length-prefixed strings, multiple-precision integers
/// and comma-separated name lists. Both the transport and SFTP are built out of these few shapes.
struct SSHWriter {
    private(set) var data = Data()
    init() {}
    init(_ initial: Data) { data = initial }
    mutating func byte(_ value: UInt8) { data.append(value) }
    mutating func bool(_ value: Bool) { data.append(value ? 1 : 0) }
    mutating func uint32(_ value: UInt32) { for shift in stride(from: 24, through: 0, by: -8) { data.append(UInt8((value >> UInt32(shift)) & 0xFF)) } }
    mutating func uint64(_ value: UInt64) { for shift in stride(from: 56, through: 0, by: -8) { data.append(UInt8((value >> UInt64(shift)) & 0xFF)) } }
    mutating func string(_ value: Data) { uint32(UInt32(value.count)); data.append(value) }
    mutating func string(_ value: String) { string(Data(value.utf8)) }
    mutating func nameList(_ names: [String]) { string(names.joined(separator: ",")) }
    /// A positive integer in two's complement: a leading zero byte keeps the high bit from reading as a sign.
    mutating func mpint(_ magnitude: Data) {
        var bytes = Data(magnitude.drop { $0 == 0 })
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        string(bytes)
    }
    mutating func raw(_ value: Data) { data.append(value) }
}

struct SSHReader {
    let data: Data
    private(set) var offset: Int
    init(_ data: Data) { self.data = data; offset = data.startIndex }
    var remaining: Int { data.endIndex - offset }
    var isAtEnd: Bool { remaining == 0 }
    struct Malformed: LocalizedError {
        var errorDescription: String? { L("El servidor SSH envió un mensaje que no se entiende.") }
    }
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else { throw Malformed() }
        let slice = Data(data[offset..<offset + count])
        offset += count
        return slice
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func bool() throws -> Bool { try byte() != 0 }
    mutating func uint32() throws -> UInt32 {
        let slice = try bytes(4)
        return slice.reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func uint64() throws -> UInt64 {
        let slice = try bytes(8)
        return slice.reduce(0) { $0 << 8 | UInt64($1) }
    }
    mutating func string() throws -> Data {
        let length = try uint32()
        guard length <= 1 << 26 else { throw Malformed() }
        return try bytes(Int(length))
    }
    mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }
    mutating func nameList() throws -> [String] {
        let joined = try text()
        return joined.isEmpty ? [] : joined.split(separator: ",").map(String.init)
    }
    /// The magnitude of a positive mpint, without its sign byte.
    mutating func mpint() throws -> Data {
        var value = try string()
        while value.first == 0 { value.removeFirst() }
        return value
    }
    mutating func rest() -> Data { let slice = Data(data[offset...]); offset = data.endIndex; return slice }
}

/// Message numbers of the transport, authentication and connection protocols that this client speaks.
enum SSHMessage {
    static let disconnect: UInt8 = 1, ignore: UInt8 = 2, unimplemented: UInt8 = 3, debug: UInt8 = 4
    static let serviceRequest: UInt8 = 5, serviceAccept: UInt8 = 6, extInfo: UInt8 = 7
    static let kexInit: UInt8 = 20, newKeys: UInt8 = 21, kexECDHInit: UInt8 = 30, kexECDHReply: UInt8 = 31
    static let userauthRequest: UInt8 = 50, userauthFailure: UInt8 = 51, userauthSuccess: UInt8 = 52, userauthBanner: UInt8 = 53
    static let userauthInfoRequest: UInt8 = 60, userauthInfoResponse: UInt8 = 61
    static let globalRequest: UInt8 = 80, requestSuccess: UInt8 = 81, requestFailure: UInt8 = 82
    static let channelOpen: UInt8 = 90, channelOpenConfirmation: UInt8 = 91, channelOpenFailure: UInt8 = 92
    static let channelWindowAdjust: UInt8 = 93, channelData: UInt8 = 94, channelExtendedData: UInt8 = 95
    static let channelEOF: UInt8 = 96, channelClose: UInt8 = 97, channelRequest: UInt8 = 98
    static let channelSuccess: UInt8 = 99, channelFailure: UInt8 = 100
}
