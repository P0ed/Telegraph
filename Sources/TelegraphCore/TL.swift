import Foundation

indirect enum TLValue: Sendable, Equatable {
    case int(Int32), long(Int64), double(Double), string(String), bytes(Data)
    case object(TLObject), vector([TLValue]), bool(Bool), raw(Data)
    var object: TLObject? { if case .object(let o) = self { return o }; return nil }
    var objects: [TLObject] { if case .vector(let a) = self { return a.compactMap(\.object) }; return [] }
    var array: [TLValue] { if case .vector(let a) = self { return a }; return [] }
    var int: Int32 { if case .int(let v) = self { return v }; return 0 }
    var long: Int64 { if case .long(let v) = self { return v }; if case .int(let v) = self { return Int64(v) }; return 0 }
    var string: String { if case .string(let v) = self { return v }; return "" }
    var bytes: Data { if case .bytes(let v) = self { return v }; return Data() }
    var bool: Bool { if case .bool(let v) = self { return v }; return false }
}

struct TLObject: Sendable, Equatable {
    let name: String
    var fields: [String: TLValue]
    init(_ name: String, _ fields: [String: TLValue] = [:]) { self.name = name; self.fields = fields }
    subscript(_ key: String) -> TLValue { fields[key] ?? .bool(false) }
}

/// Complete, pinned schema data keeps unsupported API objects decodable without
/// shipping a generated SDK. MTProto containers are framed separately by Session.
final class TLCodec: Sendable {
    struct Parameter: Decodable, Sendable { let name: String; let type: String }
    struct Definition: Decodable, Sendable {
        let id: String
        let predicate: String?
        let method: String?
        let params: [Parameter]
        let type: String
        var name: String { predicate ?? method ?? "" }
        var number: UInt32 { UInt32(truncatingIfNeeded: Int64(id)!) }
    }
    struct Schema: Decodable { let constructors: [Definition]; let methods: [Definition] }
    static let layer: Int32 = 225
    let byID: [UInt32: Definition]
    let byName: [String: Definition]

    init() throws {
        var ids: [UInt32: Definition] = [:], names: [String: Definition] = [:]
        for resource in ["mtproto-schema", "api-schema"] {
            let schema = try JSONDecoder().decode(Schema.self, from: EmbeddedSchemas.load(resource))
            for item in schema.constructors + schema.methods {
                ids[item.number] = item; names[item.name] = item
            }
        }
        byID = ids; byName = names
    }

    func encode(_ object: TLObject) throws -> Data {
        guard let def = byName[object.name] else { throw TelegraphError.invalid("Unknown TL constructor: \(object.name)") }
        var output = Data(); output.appendLE(def.number)
        try encodeFields(object, definition: def, into: &output)
        return output
    }

    private func conditional(_ type: String) -> (String, Int, String)? {
        guard let q = type.firstIndex(of: "?"), let dot = type[..<q].firstIndex(of: "."),
              let bit = Int(type[type.index(after: dot)..<q]), bit >= 0, bit < 32 else { return nil }
        return (String(type[..<dot]), bit, String(type[type.index(after: q)...]))
    }

    private func encodeFields(_ object: TLObject, definition: Definition, into output: inout Data) throws {
        var flags: [String: UInt32] = [:]
        for param in definition.params where param.type == "#" { flags[param.name] = 0 }
        for param in definition.params {
            if let (field, bit, type) = conditional(param.type), let value = object.fields[param.name],
               type != "true" || value.bool { flags[field, default: 0] |= 1 << bit }
        }
        // Several fields can share a flag; all payload fields in that group must exist.
        for param in definition.params {
            if param.type == "#" { output.appendLE(flags[param.name, default: 0]); continue }
            var type = param.type
            if let (field, bit, actual) = conditional(type) {
                guard flags[field, default: 0] & (1 << bit) != 0 else { continue }
                type = actual
                if type == "true" { continue }
            }
            guard let value = object.fields[param.name] else {
                throw TelegraphError.invalid("Missing \(object.name).\(param.name)")
            }
            try encodeValue(value, type: type, into: &output)
        }
    }

    private func encodeValue(_ value: TLValue, type: String, into out: inout Data) throws {
        if case .raw(let bytes) = value { out.append(bytes); return }
        switch (type, value) {
        case ("int", .int(let v)), ("#", .int(let v)): out.appendLE(v)
        case ("long", .long(let v)): out.appendLE(v)
        case ("double", .double(let v)): out.appendLE(v.bitPattern)
        case ("string", .string(let v)): out.append(try tlBytes(Data(v.utf8)))
        case ("bytes", .bytes(let v)): out.append(try tlBytes(v))
        case ("int128", .bytes(let v)) where v.count == 16: out.append(v)
        case ("int256", .bytes(let v)) where v.count == 32: out.append(v)
        case ("Bool", .bool(let v)): out.appendLE(UInt32(v ? 0x997275b5 : 0xbc799737))
        case (_, .vector(let values)) where type.hasPrefix("Vector<") || type.hasPrefix("vector<"):
            let inner = String(type.dropFirst(7).dropLast())
            if type.hasPrefix("Vector") { out.appendLE(UInt32(0x1cb5c415)) }
            guard values.count <= 1_000_000 else { throw TelegraphError.invalid("TL vector too large") }
            out.appendLE(Int32(values.count))
            for value in values { try encodeValue(value, type: inner, into: &out) }
        case (_, .object(let obj)):
            if type.hasPrefix("%") || byName[type]?.predicate != nil {
                guard let def = byName[obj.name] else { throw TelegraphError.invalid("Unknown bare TL type") }
                try encodeFields(obj, definition: def, into: &out)
            } else { out.append(try encode(obj)) }
        default: throw TelegraphError.invalid("Invalid value for TL type \(type)")
        }
    }

    func decode(_ data: Data, type: String = "Object") throws -> TLValue {
        var reader = BinaryReader(data: data)
        let value = try decode(&reader, type: type)
        guard reader.remaining == 0 else { throw TelegraphError.invalid("Trailing data after TL object") }
        return value
    }

    func decode(_ reader: inout BinaryReader, type: String = "Object", depth: Int = 0) throws -> TLValue {
        guard depth <= 64 else { throw TelegraphError.invalid("TL nesting exceeds limit") }
        // A packed object can replace any boxed result, including vectors.
        if reader.remaining >= 4, !["int", "long", "double", "#", "string", "bytes", "int128", "int256", "true"].contains(type) {
            var peek = reader
            if try peek.integer(UInt32.self) == 0x3072cfa1 {
                reader = peek
                let unpacked = try gunzip(reader.bytes())
                var nested = BinaryReader(data: unpacked)
                let result = try decode(&nested, type: type, depth: depth + 1)
                guard nested.remaining == 0 else { throw TelegraphError.invalid("Trailing packed TL data") }
                return result
            }
        }
        switch type {
        case "int", "#": return .int(try reader.integer())
        case "long": return .long(try reader.integer())
        case "double": return .double(Double(bitPattern: try reader.integer(UInt64.self)))
        case "string":
            guard let s = String(data: try reader.bytes(), encoding: .utf8) else { throw TelegraphError.invalid("Invalid Telegram UTF-8") }
            return .string(s)
        case "bytes": return .bytes(try reader.bytes())
        case "int128": return .bytes(try reader.read(16))
        case "int256": return .bytes(try reader.read(32))
        case "true": return .bool(true)
        default: break
        }
        if type.hasPrefix("Vector<") || type.hasPrefix("vector<") {
            if type.hasPrefix("Vector") {
                guard try reader.integer(UInt32.self) == 0x1cb5c415 else { throw TelegraphError.invalid("Invalid TL vector") }
            }
            let count = try reader.integer(Int32.self)
            guard count >= 0, count <= 1_000_000, Int(count) <= reader.remaining / 4 else {
                throw TelegraphError.invalid("Invalid TL vector count")
            }
            let inner = String(type.dropFirst(7).dropLast())
            var values: [TLValue] = []; values.reserveCapacity(Int(count))
            for _ in 0..<count { values.append(try decode(&reader, type: inner, depth: depth + 1)) }
            return .vector(values)
        }
        let def: Definition
        if let bare = byName[String(type.drop(while: { $0 == "%" }))], bare.predicate != nil {
            def = bare
        } else {
            let id = try reader.integer(UInt32.self)
            if id == 0x997275b5 { return .bool(true) }
            if id == 0xbc799737 { return .bool(false) }
            guard let known = byID[id] else {
                throw TelegraphError.invalid(String(format: "Unknown Telegram constructor %08x; update Telegraph", id))
            }
            def = known
        }
        var fields: [String: TLValue] = [:], flags: [String: UInt32] = [:]
        for param in def.params {
            var actual = param.type
            if let (field, bit, inner) = conditional(actual) {
                guard flags[field, default: 0] & (1 << bit) != 0 else { continue }
                actual = inner
            }
            let value = try decode(&reader, type: actual, depth: depth + 1)
            fields[param.name] = value
            if actual == "#" { flags[param.name] = UInt32(bitPattern: value.int) }
        }
        return .object(TLObject(def.name, fields))
    }
}
