import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum ProtocolFailure: Error { case violation, invalidArgs, invalidReference, unimplemented, deadline }

indirect enum JSON: Sendable, Equatable, Encodable {
    case object([String: JSON]), array([JSON]), string(String), number(Double), bool(Bool), null

    subscript(_ key: String) -> JSON { object?[key] ?? .null }
    var object: [String: JSON]? { if case .object(let v) = self { v } else { nil } }
    var array: [JSON]? { if case .array(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var bool: Bool? { if case .bool(let v) = self { v } else { nil } }
    var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v >= 0, v < Double(Int.max), v.rounded() == v else { return nil }
        return Int(v)
    }
    static func int(_ value: Int) -> JSON { .number(Double(value)) }
    static func optional(_ value: Int?) -> JSON { value.map(JSON.int) ?? .null }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    func fields(_ required: Set<String>, optional: Set<String> = []) throws {
        guard let object, required.isSubset(of: Set(object.keys)),
              Set(object.keys).isSubset(of: required.union(optional)) else { throw ProtocolFailure.violation }
    }

    func text(_ key: String) throws -> String {
        guard let value = self[key].string else { throw ProtocolFailure.invalidArgs }
        return value
    }
}

// Preserve object keys until uniqueness is checked, including escaped spellings of a key.
struct JSONParser {
    private var bytes: [UInt8]
    private var index = 0
    init(_ data: Data) throws {
        guard String(data: data, encoding: .utf8) != nil else { throw ProtocolFailure.violation }
        bytes = Array(data)
    }
    mutating func parse() throws -> JSON {
        let result = try value(depth: 0)
        whitespace()
        guard index == bytes.count else { throw ProtocolFailure.violation }
        return result
    }
    private mutating func whitespace() {
        while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
    }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
    private mutating func quoted() throws -> String {
        whitespace()
        let start = index
        guard take(34) else { throw ProtocolFailure.violation }
        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == 92 { index += 1 }
            if byte == 34 {
                do { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) }
                catch { throw ProtocolFailure.violation }
            }
        }
        throw ProtocolFailure.violation
    }
    private mutating func value(depth: Int) throws -> JSON {
        guard depth < 128 else { throw ProtocolFailure.violation }
        whitespace()
        guard index < bytes.count else { throw ProtocolFailure.violation }
        if bytes[index] == 34 { return .string(try quoted()) }
        if take(123) {
            var values: [String: JSON] = [:]
            if take(125) { return .object(values) }
            repeat {
                let key = try quoted()
                guard values[key] == nil, take(58) else { throw ProtocolFailure.violation }
                values[key] = try value(depth: depth + 1)
                if take(125) { return .object(values) }
            } while take(44)
            throw ProtocolFailure.violation
        }
        if take(91) {
            var values: [JSON] = []
            if take(93) { return .array(values) }
            repeat {
                values.append(try value(depth: depth + 1))
                if take(93) { return .array(values) }
            } while take(44)
            throw ProtocolFailure.violation
        }
        let start = index
        while index < bytes.count && ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
        let data = Data(bytes[start..<index])
        if data == Data("null".utf8) { return .null }
        if data == Data("true".utf8) { return .bool(true) }
        if data == Data("false".utf8) { return .bool(false) }
        guard let number = try? JSONDecoder().decode(Double.self, from: data), number.isFinite else {
            throw ProtocolFailure.violation
        }
        return .number(number)
    }
}

struct Framer {
    let limit: Int
    private var pending = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        var lines: [Data] = []
        for byte in data {
            guard pending.count < limit else { throw ProtocolFailure.violation }
            pending.append(byte)
            if byte == 10 {
                lines.append(Data(pending.dropLast()))
                pending.removeAll(keepingCapacity: true)
            }
        }
        return lines
    }
    func end() throws { guard pending.isEmpty else { throw ProtocolFailure.violation } }
}

func validRef(_ value: String) -> Bool {
    value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9:._/-]{0,255}\\z", options: .regularExpression) != nil
}

func loadCredentials(descriptor: Int32) throws -> [String: String] {
    defer { close(descriptor) }
    var framer = Framer(limit: 64 * 1024)
    var total = 0
    var values: [String: String] = [:]
    var bytes = [UInt8](repeating: 0, count: 16 * 1024)
    while true {
        let count = read(descriptor, &bytes, bytes.count)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw ProtocolFailure.violation }
        if count == 0 { break }
        total += count
        guard total <= 1024 * 1024 else { throw ProtocolFailure.violation }
        for line in try framer.append(Data(bytes.prefix(count))) {
            var parser = try JSONParser(line)
            let message = try parser.parse()
            try message.fields(["ref", "value"])
            let ref = try message.text("ref")
            guard validRef(ref), values[ref] == nil else { throw ProtocolFailure.violation }
            values[ref] = try message.text("value")
        }
    }
    try framer.end()
    return values
}
