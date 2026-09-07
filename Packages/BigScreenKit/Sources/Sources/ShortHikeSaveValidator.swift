import Foundation

/// Reads MS-NRBF data as bounded values, never loading assemblies or instantiating game classes.
/// This validates the acceptance title's persisted structure, not the player's game progress.
enum ShortHikeSaveValidator {
    static func validate(_ data: Data, filename: String) throws {
        guard data.count <= 20_000_000 else { throw NRBFSaveReader.Invalid(reason: "Oversized save", offset: 0) }
        var reader = NRBFSaveReader(data: Array(data))
        let root = try reader.parse()
        let fields = try reader.object(root, named: "GlobalData+GameData")
        guard case .reference(let nameID) = fields["fileName"], case .string(let savedName) = reader.objects[nameID],
              savedName == filename else { throw reader.invalid("Save filename does not match its root object") }
        let tags = try reader.object(fields["tags"], named: "Tags")
        for field in ["bools", "ints", "floats", "strings"] {
            _ = try reader.object(tags[field], prefix: "System.Collections.Generic.Dictionary`2[[System.String,")
        }
        _ = try reader.object(fields["inventory"], named: "GlobalData+CollectionInventory")
        _ = try reader.object(fields["playerReplayData"], prefix: "System.Collections.Generic.Dictionary`2[[System.String,")
        _ = try reader.object(fields["allCollectedNames"], prefix: "System.Collections.Generic.List`1[[System.String,")
        try reader.validateCollections()
    }
}

private struct NRBFSaveReader {
    enum Value { case reference(Int32), primitive(UInt8, Int64?), null }
    enum Node { case reserved, object(String, [String: Value]), array([Value], TypeInfo), string(String) }
    struct TypeInfo { let kind: UInt8; var primitive: UInt8?; var name: String? }
    struct Metadata { let name: String; let names: [String]; let types: [TypeInfo] }
    enum Record { case value(Value), nulls(Int), library }
    struct Invalid: Error { let reason: String; let offset: Int }
    let data: [UInt8]
    var offset = 0
    var objects: [Int32: Node] = [:]
    var metadata: [Int32: Metadata] = [:]
    var libraries = Set<Int32>()
    var references = Set<Int32>()
    var typeChecks: [(Value, TypeInfo)] = []
    var slots = 0, records = 0, depth = 0
    func invalid(_ reason: String) -> Invalid { .init(reason: reason, offset: offset) }

    mutating func parse() throws -> Value {
        guard data.count <= 20_000_000, try byte() == 0 else { throw invalid("Missing or oversized serialization header") }
        let root = try integer(); _ = try integer()
        guard root > 0, try integer() == 1, try integer() == 0 else { throw invalid("Unsupported serialization version") }
        while try peek() != 11 {
            let tag = try peek()
            guard [1, 4, 5, 6, 7, 12, 15, 16, 17].contains(tag) else { throw invalid("Unexpected top-level record") }
            _ = try record()
        }
        _ = try byte()
        guard offset == data.count, references.isSubset(of: Set(objects.keys)), objects[root] != nil else {
            throw invalid("Incomplete graph or trailing data")
        }
        for (value, type) in typeChecks { try check(value, type: type) }
        return .reference(root)
    }

    func object(_ value: Value?, named name: String? = nil, prefix: String? = nil) throws -> [String: Value] {
        guard case .reference(let id) = value, case .object(let actual, let members) = objects[id],
              name.map({ actual == $0 }) ?? true, prefix.map({ actual.hasPrefix($0) }) ?? true else {
            throw invalid("Missing or unexpected game save object")
        }
        return members
    }

    func validateCollections() throws {
        for node in objects.values {
            guard case .object(let name, let fields) = node else { continue }
            if name.hasPrefix("System.Collections.Generic.List`1[") {
                guard case .primitive(8, let size?) = fields["_size"], size >= 0,
                      case .reference(let id) = fields["_items"], case .array(let values, _) = objects[id],
                      size <= values.count else { throw invalid("Invalid list length") }
            } else if name.hasPrefix("System.Collections.Generic.Dictionary`2[") {
                guard case .primitive(8, let size?) = fields["HashSize"], size >= 0 else { throw invalid("Invalid dictionary size") }
                if let pairs = fields["KeyValuePairs"] {
                    guard case .reference(let id) = pairs, case .array(let values, _) = objects[id],
                          values.count <= size else { throw invalid("Incomplete dictionary entries") }
                } else if size != 0 { throw invalid("Missing dictionary entries") }
            }
        }
    }

    func check(_ value: Value, type: TypeInfo) throws {
        if case .null = value { return }
        if type.kind == 2 { return }
        guard case .reference(let id) = value, let node = objects[id] else { throw invalid("Value does not match its declared type") }
        switch (type.kind, node) {
        case (1, .string): return
        case (3, .object), (4, .object):
            guard type.name?.hasSuffix("[]") != true else { throw invalid("An array field references an object") }
            return
        case (3, .array(_, let element)), (4, .array(_, let element)):
            // NRBF uses SystemClass/Class names for arrays of named types as well as objects.
            guard let name = type.name, name.hasSuffix("[]"), element.name == String(name.dropLast(2)) else {
                throw invalid("Array does not match its declared class element type")
            }
            return
        case (5, .array(_, let element)) where element.kind != 0: return
        case (6, .array(_, let element)) where element.kind == 1: return
        case (7, .array(_, let element)) where element.kind == 0 && element.primitive == type.primitive: return
        default: throw invalid("Object does not match its declared type")
        }
    }

    mutating func record() throws -> Record {
        records += 1; depth += 1; defer { depth -= 1 }
        guard records <= 200_000, depth <= 128 else { throw invalid("Record or nesting limit exceeded") }
        try Task.checkCancellation()
        switch try byte() {
        case 12:
            let id = try integer()
            guard id > 0, libraries.insert(id).inserted, !(try string()).isEmpty else { throw invalid("Invalid library record") }
            return .library
        case 4, 5:
            let tag = data[offset - 1], id = try integer(), name = try string(), count = try count(limit: 1_024)
            var names: [String] = [], kinds: [UInt8] = [], types: [TypeInfo] = []
            for _ in 0..<count { names.append(try string()) }
            guard Set(names).count == names.count, !name.isEmpty else { throw invalid("Invalid member names") }
            for _ in 0..<count { kinds.append(try byte()) }
            for kind in kinds { types.append(try type(kind)) }
            if tag == 5 { guard libraries.contains(try integer()) else { throw invalid("Unknown class library") } }
            let info = Metadata(name: name, names: names, types: types)
            try reserve(id); metadata[id] = info
            objects[id] = .object(name, try members(info))
            return .value(.reference(id))
        case 1:
            let id = try integer(), metadataID = try integer()
            guard let info = metadata[metadataID] else { throw invalid("Unknown class metadata") }
            try reserve(id); objects[id] = .object(info.name, try members(info))
            return .value(.reference(id))
        case 6:
            let id = try integer(); try reserve(id); objects[id] = .string(try string())
            return .value(.reference(id))
        case 7, 15, 16, 17:
            let tag = data[offset - 1], id = try integer(); try reserve(id)
            guard id > 0 else { throw invalid("Invalid array identity") }
            let length: Int, element: TypeInfo
            if tag == 7 {
                let shape = try byte(), rank = try count(limit: 32)
                guard shape <= 5, rank > 0, (shape == 2 || shape == 5 || rank == 1) else { throw invalid("Unsupported array shape") }
                var product = 1
                for _ in 0..<rank {
                    let size = try count(limit: 1_000_000)
                    guard size == 0 || product <= 1_000_000 / size else { throw invalid("Array size limit exceeded") }
                    product *= size
                }
                if shape >= 3 { for _ in 0..<rank { _ = try integer() } }
                length = product; element = try type(byte())
            } else {
                length = try count(limit: 1_000_000)
                element = tag == 15 ? try type(0) : TypeInfo(kind: tag == 16 ? 2 : 1)
            }
            objects[id] = .array(try array(length, element: element), element)
            return .value(.reference(id))
        case 8:
            return .value(try primitive(primitiveType()))
        case 9:
            let id = try integer(); references.insert(id)
            return .value(.reference(id))
        case 10: return .value(.null)
        case 13, 14:
            let tag = data[offset - 1], length = tag == 13 ? Int(try byte()) : try count(limit: 1_000_000)
            guard length > 0 else { throw invalid("Empty null run") }
            return .nulls(length)
        default: throw invalid("Unsupported or misplaced serialization record")
        }
    }

    mutating func members(_ info: Metadata) throws -> [String: Value] {
        try takeSlots(info.names.count)
        var values: [String: Value] = [:]
        for (name, type) in zip(info.names, info.types) {
            if type.kind == 0 { values[name] = try primitive(type.primitive!); continue }
            var next = try record()
            while case .library = next { next = try record() }
            guard case .value(let value) = next else { throw invalid("Null run outside an array") }
            typeChecks.append((value, type))
            values[name] = value
        }
        return values
    }
    mutating func array(_ count: Int, element: TypeInfo) throws -> [Value] {
        try takeSlots(count)
        var values: [Value] = []; values.reserveCapacity(count)
        while values.count < count {
            if element.kind == 0 { values.append(try primitive(element.primitive!)); continue }
            switch try record() {
            case .library: continue
            case .value(let value): values.append(value); typeChecks.append((value, element))
            case .nulls(let length):
                guard length <= count - values.count else { throw invalid("Null run exceeds array") }
                values.append(contentsOf: repeatElement(.null, count: length))
            }
        }
        return values
    }
    mutating func type(_ kind: UInt8) throws -> TypeInfo {
        switch kind {
        case 0, 7: return TypeInfo(kind: kind, primitive: try primitiveType())
        case 3: return TypeInfo(kind: kind, name: try string())
        case 4:
            let name = try string()
            guard libraries.contains(try integer()) else { throw invalid("Unknown member library") }
            return TypeInfo(kind: kind, name: name)
        case 1, 2, 5, 6: break
        default: throw invalid("Unknown member type")
        }
        return TypeInfo(kind: kind)
    }
    mutating func primitiveType() throws -> UInt8 {
        let value = try byte()
        guard (1...16).contains(value), value != 4 else { throw invalid("Unknown primitive type") }
        return value
    }
    mutating func primitive(_ kind: UInt8) throws -> Value {
        switch kind {
        case 1:
            let value = try byte(); guard value <= 1 else { throw invalid("Invalid boolean") }
            return .primitive(kind, Int64(value))
        case 2, 10: _ = try byte()
        case 3:
            let first = try peek(), length = first < 0x80 ? 1 : first >= 0xC2 && first <= 0xDF ? 2 : first >= 0xE0 && first <= 0xEF ? 3 : 0
            guard length > 0, let text = String(bytes: try bytes(length), encoding: .utf8), text.unicodeScalars.count == 1 else { throw invalid("Invalid character") }
        case 5:
            guard let value = Double(try string()), value.isFinite else { throw invalid("Invalid decimal") }
        case 6:
            guard Double(bitPattern: try unsigned(8)).isFinite else { throw invalid("Invalid floating point value") }
        case 7, 14: _ = try bytes(2)
        case 8: return .primitive(kind, Int64(try integer()))
        case 9, 12, 13, 16: _ = try bytes(8)
        case 11:
            guard Float(bitPattern: UInt32(try unsigned(4))).isFinite else { throw invalid("Invalid floating point value") }
        case 15: _ = try bytes(4)
        default: throw invalid("Unsupported primitive")
        }
        return .primitive(kind, nil)
    }
    mutating func reserve(_ id: Int32) throws {
        guard id != 0, objects.count < 200_000, objects[id] == nil else { throw invalid("Duplicate object identity") }
        objects[id] = .reserved
    }
    mutating func takeSlots(_ count: Int) throws {
        guard count <= 1_000_000 - slots else { throw invalid("Save graph size limit exceeded") }
        slots += count
    }
    func peek() throws -> UInt8 {
        guard offset < data.count else { throw invalid("Truncated save") }; return data[offset]
    }
    mutating func byte() throws -> UInt8 { let value = try peek(); offset += 1; return value }
    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= data.count - offset else { throw invalid("Truncated save") }
        defer { offset += count }; return data[offset..<offset + count]
    }
    mutating func unsigned(_ count: Int) throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<count { value |= UInt64(try byte()) << (index * 8) }
        return value
    }
    mutating func integer() throws -> Int32 { Int32(bitPattern: UInt32(try unsigned(4))) }
    mutating func count(limit: Int) throws -> Int {
        let value = Int(try integer()); guard value >= 0, value <= limit else { throw invalid("Invalid record length") }; return value
    }
    mutating func string() throws -> String {
        var count = 0
        for index in 0..<5 {
            let value = try byte()
            guard index < 4 || value < 8 else { throw invalid("Invalid string length encoding") }
            count |= Int(value & 0x7F) << (index * 7)
            if value < 0x80 {
                guard count <= 1_048_576, let text = String(bytes: try bytes(count), encoding: .utf8) else { throw invalid("Invalid UTF-8 string") }
                return text
            }
        }
        throw invalid("Invalid string length encoding")
    }
}
