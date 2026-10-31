#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct RequestContext: Codable, Sendable {
    public let method: String
    public let uri: String
    public let headers: [String: String]

    public init(method: String, uri: String, headers: [String: String]) {
        self.method = method
        self.uri = uri
        self.headers = headers
    }
}

public struct ApplicationOptions: Sendable {
    public init() {}
}

public struct OperationError: Error, Sendable {
    public static let notImplemented = OperationError()
    private init() {}
}

@_spi(Generated)
public struct _InputBudgetExceeded: Error, Sendable {
    public init() {}
}

public struct ServerResponse: Sendable {
    public let status: Int
    public let body: Data

    static func failure(_ code: String, status: Int) -> ServerResponse {
        ServerResponse(status: status, body: Data("{\"error\":\"\(code)\"}".utf8))
    }
}

public struct Operation: Sendable {
    let name: String
    let invoke: @Sendable (JSONValue, RequestContext) async -> ServerResponse

    public init<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ name: String, input: Input.Type,
        handler: @escaping @Sendable (Input, RequestContext) async throws -> Output
    ) {
        self.name = name
        invoke = { body, context in
            let value: Input
            do { value = try Input(from: JSONValueDecoder(body)) }
            catch is _InputBudgetExceeded { return .failure("request_too_large", status: 413) }
            catch { return .failure("invalid_input", status: 400) }
            do {
                let output = try await handler(value, context)
                return try ServerResponse(status: 200, body: JSONEncoder().encode(output))
            } catch is OperationError {
                return .failure("not_implemented", status: 501)
            } catch {
                return .failure("operation_failed", status: 500)
            }
        }
    }
}

public struct Application: Sendable {
    private let operations: [String: Operation]

    public init(operations: [Operation]) {
        self.operations = Dictionary(uniqueKeysWithValues: operations.map { ($0.name, $0) })
    }

    public func handle(_ operation: String, body: Data, context: RequestContext) async -> ServerResponse {
        guard let target = operations[operation] else { return .failure("not_found", status: 404) }
        guard context.method == "POST" else { return .failure("method_not_allowed", status: 405) }
        guard body.count <= 4 << 20 else { return .failure("request_too_large", status: 413) }
        do {
            let parsed = try JSONBody.parse(body)
            return await target.invoke(parsed, context)
        } catch let error as JSONBody.Failure {
            return .failure(error.rawValue, status: 400)
        } catch {
            return .failure("invalid_json", status: 400)
        }
    }
}

struct JSONBody {
    enum Failure: String, Error { case syntax = "invalid_json", structure = "invalid_input" }
    private enum State: UInt8 { case end, value, objectFirst, objectKey, colon, objectEnd, arrayFirst, arrayEnd }
    private struct Frame {
        var keys: [[UInt8]: Int] = [:]
        var members: [(key: String, value: JSONValue)] = []
        var key: String?
        var elements: [JSONValue] = []
        let object: Bool
    }

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private var validStructure = true
    private var frames: [Frame] = []
    private var root: JSONValue?
    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    static func parse(_ body: Data, requireObject: Bool = true) throws -> JSONValue {
        guard String(data: body, encoding: .utf8) != nil else { throw Failure.syntax }
        var parser = JSONBody(bytes: Array(body))
        return try parser.validate(requireObject: requireObject)
    }

    private mutating func validate(requireObject: Bool) throws -> JSONValue {
        whitespace()
        let object = current == 123
        var states: [State] = [.end, .value]
        // Foundation limits nesting and skips unknown numbers; validate syntax without either restriction.
        while let state = states.popLast() {
            whitespace()
            switch state {
            case .end:
                guard index == bytes.count else { throw Failure.syntax }
            case .value:
                guard let byte = current else { throw Failure.syntax }
                switch byte {
                case 123, 91:
                    index += 1
                    depth += 1
                    if depth > 64 { validStructure = false }
                    if validStructure {
                        frames.append(Frame(object: byte == 123))
                    }
                    states.append(byte == 123 ? .objectFirst : .arrayFirst)
                case 34:
                    let value = try string()
                    append(.string(value))
                case 45, 48...57:
                    let value = try number()
                    append(.number(value))
                case 116: try literal("true"); append(.bool(true))
                case 102: try literal("false"); append(.bool(false))
                case 110: try literal("null"); append(.null)
                default: throw Failure.syntax
                }
            case .objectFirst, .objectKey:
                if state == .objectFirst, current == 125 {
                    index += 1
                    depth -= 1
                    close()
                } else {
                    let key = try string()
                    if validStructure {
                        let last = frames.count - 1
                        if frames[last].keys.updateValue(frames[last].members.count, forKey: Array(key.utf8)) != nil {
                            validStructure = false
                        }
                        frames[last].key = key
                    }
                    states.append(contentsOf: [.objectEnd, .value, .colon])
                }
            case .colon:
                guard current == 58 else { throw Failure.syntax }
                index += 1
            case .objectEnd:
                if current == 125 {
                    index += 1
                    depth -= 1
                    close()
                } else {
                    guard current == 44 else { throw Failure.syntax }
                    index += 1
                    states.append(.objectKey)
                }
            case .arrayFirst:
                if current == 93 {
                    index += 1
                    depth -= 1
                    close()
                } else {
                    states.append(contentsOf: [.arrayEnd, .value])
                }
            case .arrayEnd:
                if current == 93 {
                    index += 1
                    depth -= 1
                    close()
                } else {
                    guard current == 44 else { throw Failure.syntax }
                    index += 1
                    states.append(contentsOf: [.arrayEnd, .value])
                }
            }
        }
        guard (!requireObject || object), validStructure, let root else { throw Failure.structure }
        return root
    }

    private mutating func append(_ value: JSONValue) {
        guard validStructure else { return }
        guard !frames.isEmpty else { root = value; return }
        let last = frames.count - 1
        if frames[last].object {
            frames[last].members.append((frames[last].key!, value))
            frames[last].key = nil
        } else {
            frames[last].elements.append(value)
        }
    }

    private mutating func close() {
        guard validStructure else { return }
        let frame = frames.removeLast()
        append(frame.object ? .object(frame.members, frame.keys) : .array(frame.elements))
    }

    private mutating func whitespace() {
        while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    private mutating func string() throws -> String {
        guard current == 34 else { throw Failure.syntax }
        index += 1
        var key: [UInt8] = []
        var highSurrogate: UInt32?
        while let byte = current {
            index += 1
            switch byte {
            case 34:
                if highSurrogate != nil { validStructure = false }
                return String(decoding: key, as: UTF8.self)
            case 0...31: throw Failure.syntax
            case 92:
                guard let escape = current else { throw Failure.syntax }
                index += 1
                var scalar: UInt32
                switch escape {
                case 34, 47, 92: scalar = UInt32(escape)
                case 98: scalar = 8
                case 102: scalar = 12
                case 110: scalar = 10
                case 114: scalar = 13
                case 116: scalar = 9
                case 117:
                    scalar = 0
                    for _ in 0..<4 {
                        guard let hex = current else { throw Failure.syntax }
                        let digit: UInt32
                        switch hex {
                        case 48...57: digit = UInt32(hex - 48)
                        case 65...70: digit = UInt32(hex - 55)
                        case 97...102: digit = UInt32(hex - 87)
                        default: throw Failure.syntax
                        }
                        scalar = scalar * 16 + digit
                        index += 1
                    }
                default: throw Failure.syntax
                }
                if let high = highSurrogate {
                    highSurrogate = nil
                    if (0xDC00...0xDFFF).contains(scalar) {
                        scalar = 0x10000 + (high - 0xD800) * 0x400 + scalar - 0xDC00
                    } else {
                        validStructure = false
                    }
                }
                if (0xD800...0xDBFF).contains(scalar) {
                    highSurrogate = scalar
                } else if (0xDC00...0xDFFF).contains(scalar) {
                    validStructure = false
                } else if validStructure {
                    key.append(contentsOf: String(UnicodeScalar(scalar)!).utf8)
                }
            default:
                if highSurrogate != nil {
                    validStructure = false
                    highSurrogate = nil
                }
                if validStructure { key.append(byte) }
            }
        }
        throw Failure.syntax
    }

    private mutating func literal(_ value: String) throws {
        for byte in value.utf8 {
            guard current == byte else { throw Failure.syntax }
            index += 1
        }
    }

    private mutating func digits() -> Bool {
        let start = index
        while let byte = current, (48...57).contains(byte) { index += 1 }
        return index > start
    }

    private mutating func number() throws -> String {
        let start = index
        if current == 45 { index += 1 }
        if current == 48 { index += 1 }
        else {
            guard let first = current, (49...57).contains(first), digits() else { throw Failure.syntax }
        }
        if current == 46 {
            index += 1
            guard digits() else { throw Failure.syntax }
        }
        if current == 69 || current == 101 {
            index += 1
            if current == 43 || current == 45 { index += 1 }
            guard digits() else { throw Failure.syntax }
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if Double(token)?.isFinite != true { validStructure = false }
        return token
    }
}
