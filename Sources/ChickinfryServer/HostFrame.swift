#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

enum HostValue: Codable, Sendable, Equatable {
    case null, bool(Bool), integer(Int64), number(Double), string(String)
    case array([HostValue]), object([String: HostValue])

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .bool(flag) }
        else if let integer = try? value.decode(Int64.self) {
            guard (-9_007_199_254_740_991...9_007_199_254_740_991).contains(integer) else { throw HostFailure.invalidFrame }
            self = .integer(integer)
        } else if let number = try? value.decode(Double.self) {
            guard number.isFinite, abs(number) <= 9_007_199_254_740_991 else { throw HostFailure.invalidFrame }
            self = .number(number)
        } else if let string = try? value.decode(String.self) { self = .string(string) }
        else if let array = try? value.decode([HostValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: HostValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let flag): try value.encode(flag)
        case .integer(let integer): try value.encode(integer)
        case .number(let number): try value.encode(number)
        case .string(let string): try value.encode(string)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }

    var handle: UInt64? {
        guard case .integer(let value) = self, value > 0, value <= 9_007_199_254_740_991 else { return nil }
        return UInt64(value)
    }
}

struct HostFailure: Error, Sendable {
    let code: String
    static let invalidFrame = HostFailure(code: "invalid_host_call")
    static let transport = HostFailure(code: "database_failed")
}

enum HostChannel: Int32, Sendable { case database = 0, environment = 1, log = 2, finish = 3 }

enum HostFrame {
    static func decode(_ data: Data) throws -> [String: HostValue] {
        guard String(data: data, encoding: .utf8) != nil else { throw HostFailure.invalidFrame }
        let bytes = Array(data)
        var objects: [Set<String>] = []
        var index = 0
        // Codable accepts duplicate keys; validate their decoded spelling before decoding values.
        while index < bytes.count {
            switch bytes[index] {
            case 123: objects.append([])
            case 125:
                guard !objects.isEmpty else { throw HostFailure.invalidFrame }
                objects.removeLast()
            case 34:
                let start = index
                index += 1
                while index < bytes.count, bytes[index] != 34 {
                    if bytes[index] == 92 { index += 1 }
                    index += 1
                }
                guard index < bytes.count else { throw HostFailure.invalidFrame }
                var next = index + 1
                while next < bytes.count, [9, 10, 13, 32].contains(bytes[next]) { next += 1 }
                if next < bytes.count, bytes[next] == 58 {
                    guard !objects.isEmpty else { throw HostFailure.invalidFrame }
                    let key = try JSONDecoder().decode(String.self, from: Data(bytes[start...index]))
                    guard objects[objects.count - 1].insert(key).inserted else { throw HostFailure.invalidFrame }
                }
            case 45, 48...57:
                let start = index
                while index < bytes.count, (48...57).contains(bytes[index]) || [43, 45, 46, 69, 101].contains(bytes[index]) {
                    index += 1
                }
                try validateNumber(String(decoding: bytes[start..<index], as: UTF8.self))
                continue
            default: break
            }
            index += 1
        }
        return try JSONDecoder().decode([String: HostValue].self, from: data)
    }

    private static func validateNumber(_ token: String) throws {
        let parts = token.split(whereSeparator: { $0 == "e" || $0 == "E" })
        guard let mantissa = parts.first else { throw HostFailure.invalidFrame }
        let digits = mantissa.utf8.filter { (48...57).contains($0) }
        let significant = digits.drop(while: { $0 == 48 })
        guard !significant.isEmpty else { return }
        guard let exponent = parts.count == 1 ? 0 : Int(parts[1]) else { throw HostFailure.invalidFrame }
        let integerDigits = mantissa.prefix(while: { $0 != "." }).utf8.filter { (48...57).contains($0) }.count
        let (position, overflow) = exponent.addingReportingOverflow(integerDigits - (digits.count - significant.count))
        guard !overflow, position <= 16 else { throw HostFailure.invalidFrame }
        // Compare decimal digits before Double can round a value back inside the safe range.
        if position == 16 {
            let leading = Array(significant.prefix(16)) + Array(repeating: UInt8(48), count: max(0, 16 - significant.count))
            let limit = Array("9007199254740991".utf8)
            guard leading.lexicographicallyPrecedes(limit)
                || (leading == limit && significant.dropFirst(16).allSatisfy({ $0 == 48 })) else { throw HostFailure.invalidFrame }
        }
        guard let number = Double(token), number.isFinite, number != 0 else { throw HostFailure.invalidFrame }
        guard number.rounded(.towardZero) != number
            || significant.dropFirst(max(0, position)).allSatisfy({ $0 == 48 }) else { throw HostFailure.invalidFrame }
    }

    static func encode(_ frame: [String: HostValue]) throws -> Data { try JSONEncoder().encode(frame) }

    static func request(_ channel: HostChannel, bytes: Data, rid: UInt64) throws -> (Data, String) {
        var frame = try decode(bytes)
        let operation: String
        let fields: Set<String>
        switch channel {
        case .database:
            guard case .string(let op) = frame["op"] else { throw HostFailure.invalidFrame }
            operation = op
            switch op {
            case "query": fields = ["op", "sql", "params"]
            case "begin": fields = ["op"]
            case "exec": fields = ["op", "lease", "sql", "params"]
            case "commit", "rollback": fields = ["op", "lease"]
            default: throw HostFailure.invalidFrame
            }
            if fields.contains("sql") {
                guard case .string = frame["sql"], case .array = frame["params"] else { throw HostFailure.invalidFrame }
            }
            if fields.contains("lease"), frame["lease"]?.handle == nil { throw HostFailure.invalidFrame }
        case .environment:
            operation = "env"; fields = ["name"]
            guard case .string = frame["name"] else { throw HostFailure.invalidFrame }
        case .log:
            operation = "log"; fields = ["level", "message"]
            guard case .string(let level) = frame["level"], ["debug", "info", "warn", "error"].contains(level),
                  case .string = frame["message"] else { throw HostFailure.invalidFrame }
        case .finish: throw HostFailure.invalidFrame
        }
        guard Set(frame.keys) == fields else { throw HostFailure.invalidFrame }
        frame["rid"] = .integer(Int64(rid))
        return (try encode(frame), operation)
    }

    static func response(_ operation: String, bytes: Data) throws -> [String: HostValue] {
        let frame = try decode(bytes)
        if let error = frame["error"] {
            guard frame.count == 1, case .string(let code) = error else { throw HostFailure.invalidFrame }
            let allowed: Bool
            switch operation {
            case "query", "begin", "exec", "commit", "rollback":
                allowed = ["database_failed", "commit_unknown", "invalid_host_call"].contains(code)
                    || (code.utf8.count == 5 && code.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }))
            case "env": allowed = ["binding_unavailable", "invalid_host_call"].contains(code)
            case "log": allowed = ["log_failed", "invalid_host_call"].contains(code)
            default: allowed = false
            }
            guard allowed else { throw HostFailure.invalidFrame }
            return frame
        }
        switch operation {
        case "query", "exec":
            guard frame.count == 1, case .array(let rows) = frame["rows"],
                  rows.allSatisfy({ if case .object = $0 { true } else { false } }) else { throw HostFailure.invalidFrame }
        case "begin":
            guard frame.count == 1, frame["lease"]?.handle != nil else { throw HostFailure.invalidFrame }
        case "env":
            guard frame.count == 1, let value = frame["value"], value == .null || { if case .string = value { true } else { false } }() else {
                throw HostFailure.invalidFrame
            }
        default: guard frame.isEmpty else { throw HostFailure.invalidFrame }
        }
        return frame
    }
}
