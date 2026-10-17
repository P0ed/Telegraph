import Foundation
import zlib

enum TelegraphError: Error, CustomStringConvertible, Sendable {
    case invalid(String), connection(String), timeout, rpc(Int32, String), cancelled
    var description: String {
        switch self {
        case .invalid(let s): return s
        case .connection(let s): return "Connection: \(s)"
        case .timeout: return "Telegram did not respond in time. Try again."
        case .rpc(_, let s): return s
        case .cancelled: return "Cancelled"
        }
    }
    var rpcMessage: String? { if case .rpc(_, let s) = self { return s }; return nil }
}

extension Data {
    init(hex: String) throws {
        let s = hex.filter { !$0.isWhitespace }
        guard s.count.isMultiple(of: 2) else { throw TelegraphError.invalid("Invalid hexadecimal data") }
        self.init()
        var i = s.startIndex
        while i < s.endIndex {
            let end = s.index(i, offsetBy: 2)
            guard let b = UInt8(s[i..<end], radix: 16) else { throw TelegraphError.invalid("Invalid hex byte") }
            append(b); i = end
        }
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    func slice(_ range: Range<Int>) -> Data { Data(self[index(startIndex, offsetBy: range.lowerBound)..<index(startIndex, offsetBy: range.upperBound)]) }
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var value = v.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
    func constantEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func xor(_ a: Data, _ b: Data) -> Data { Data(zip(a, b).map(^)) }
}

struct BinaryReader {
    let data: Data
    var offset = 0
    var remaining: Int { data.count - offset }
    mutating func read(_ count: Int) throws -> Data {
        guard count >= 0, count <= remaining else { throw TelegraphError.invalid("Truncated Telegram packet") }
        defer { offset += count }
        return data.slice(offset..<offset + count)
    }
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) throws -> T {
        let bytes = try read(MemoryLayout<T>.size)
        return bytes.enumerated().reduce(T(0)) { $0 | T(truncatingIfNeeded: $1.element) << ($1.offset * 8) }
    }
    mutating func bytes() throws -> Data {
        let first: UInt8 = try integer()
        var header = 1
        let length: Int
        if first == 254 {
            let b = try read(3)
            length = Int(b[0]) | Int(b[1]) << 8 | Int(b[2]) << 16
            header = 4
        } else if first < 254 { length = Int(first) }
        else { throw TelegraphError.invalid("Invalid TL byte length") }
        let result = try read(length)
        let pad = try read((4 - (header + length) % 4) % 4)
        guard pad.allSatisfy({ $0 == 0 }) else { throw TelegraphError.invalid("Invalid TL padding") }
        return result
    }
}

func tlBytes(_ bytes: Data) throws -> Data {
    guard bytes.count <= 0xffffff else { throw TelegraphError.invalid("TL byte string too large") }
    var data = Data()
    if bytes.count < 254 { data.append(UInt8(bytes.count)) }
    else {
        data.append(254)
        data.append(UInt8(truncatingIfNeeded: bytes.count))
        data.append(UInt8(truncatingIfNeeded: bytes.count >> 8))
        data.append(UInt8(truncatingIfNeeded: bytes.count >> 16))
    }
    data.append(bytes)
    data.append(contentsOf: repeatElement(0, count: (4 - data.count % 4) % 4))
    return data
}

func gunzip(_ data: Data, limit: Int = 32 * 1024 * 1024) throws -> Data {
    guard !data.isEmpty else { throw TelegraphError.invalid("Empty gzip data") }
    var stream = z_stream()
    guard inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
        throw TelegraphError.invalid("Could not initialize gzip")
    }
    defer { inflateEnd(&stream) }
    return try data.withUnsafeBytes { raw in
        stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: Bytef.self).baseAddress!)
        stream.avail_in = uInt(data.count)
        var output = Data()
        var chunk = [UInt8](repeating: 0, count: 32_768)
        while true {
            let status = chunk.withUnsafeMutableBytes { bytes -> Int32 in
                stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress!
                stream.avail_out = uInt(bytes.count)
                return inflate(&stream, Z_NO_FLUSH)
            }
            let produced = chunk.count - Int(stream.avail_out)
            guard output.count <= limit - produced else { throw TelegraphError.invalid("Decompressed packet exceeds limit") }
            output.append(contentsOf: chunk.prefix(produced))
            if status == Z_STREAM_END {
                guard stream.avail_in == 0 else { throw TelegraphError.invalid("Trailing gzip data") }
                return output
            }
            guard status == Z_OK, produced > 0 || stream.avail_in > 0 else {
                throw TelegraphError.invalid("Corrupt gzip data")
            }
        }
    }
}
