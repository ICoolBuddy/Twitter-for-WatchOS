import Foundation

/// A tolerant, dynamically typed JSON value.
///
/// X's GraphQL responses are deeply nested and change shape often. Instead of
/// strict `Decodable` models (which fail on the first unexpected field), the
/// parsers walk a `JSON` tree where every missing key simply yields `.null`.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    // MARK: Parsing

    public init(data: Data) throws {
        let any = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        self = JSON(any: any)
    }

    public init(any: Any?) {
        switch any {
        case nil, is NSNull:
            self = .null
        case let v as NSNumber:
            // NSNumber bridges both Bool and numbers; distinguish via objCType / CFBoolean.
            if JSON.isBool(v) { self = .bool(v.boolValue) } else { self = .number(v.doubleValue) }
        case let v as String:
            self = .string(v)
        case let v as [Any]:
            self = .array(v.map { JSON(any: $0) })
        case let v as [String: Any]:
            var out: [String: JSON] = [:]
            out.reserveCapacity(v.count)
            for (k, val) in v { out[k] = JSON(any: val) }
            self = .object(out)
        case let v as Bool:
            self = .bool(v)
        case let v as Int:
            self = .number(Double(v))
        case let v as Double:
            self = .number(v)
        default:
            self = .null
        }
    }

    private static func isBool(_ n: NSNumber) -> Bool {
        #if canImport(Darwin)
        return CFGetTypeID(n) == CFBooleanGetTypeID()
        #else
        // swift-corelibs-foundation: Bool-backed NSNumbers report objCType "c"
        // and are exactly 0 or 1. JSONSerialization on Linux produces real Bool
        // values for true/false, which hit the `as Bool` branch only if this
        // returns true here.
        let t = String(cString: n.objCType)
        return t == "c" || t == "B"
        #endif
    }

    // MARK: Access

    public subscript(key: String) -> JSON {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }

    public subscript(index: Int) -> JSON {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return .null
    }

    /// Follows a dotted path, e.g. `json[path: "data.user.result"]`.
    public subscript(path path: String) -> JSON {
        var cur = self
        for part in path.split(separator: ".") { cur = cur[String(part)] }
        return cur
    }

    public var isNull: Bool { if case .null = self { return true }; return false }

    public var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        default: return nil
        }
    }

    public var int: Int? {
        switch self {
        case .number(let n): return Int(exactly: n.rounded()) ?? nil
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    public var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let n): return n != 0
        case .string(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }

    public var array: [JSON] { if case .array(let a) = self { return a }; return [] }
    public var object: [String: JSON] { if case .object(let o) = self { return o }; return [:] }

    // MARK: Serialization

    public var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n.rounded() == n && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map { $0.anyValue }
        case .object(let o): return o.mapValues { $0.anyValue }
        }
    }

    public func data(sortedKeys: Bool = true) -> Data {
        var opts: JSONSerialization.WritingOptions = [.fragmentsAllowed, .withoutEscapingSlashes]
        if sortedKeys { opts.insert(.sortedKeys) }
        return (try? JSONSerialization.data(withJSONObject: anyValue, options: opts)) ?? Data("null".utf8)
    }

    public func encodedString() -> String {
        String(decoding: data(), as: UTF8.self)
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral
{
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o: [String: JSON] = [:]
        for (k, v) in elements { o[k] = v }
        self = .object(o)
    }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(nilLiteral: ()) { self = .null }
}

extension JSON: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSON].self) { self = .object(o) }
        else { self = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
