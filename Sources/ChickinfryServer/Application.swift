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
    let invoke: @Sendable (Data, RequestContext) async -> ServerResponse

    public init<Input: Decodable & Sendable, Output: Encodable & Sendable>(
        _ name: String, input: Input.Type,
        handler: @escaping @Sendable (Input, RequestContext) async throws -> Output
    ) {
        self.name = name
        invoke = { body, context in
            let value: Input
            do { value = try JSONDecoder().decode(Input.self, from: body) }
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
        if let error = JSONBody.error(in: body) {
            return .failure(error, status: 400)
        }
        return await target.invoke(body, context)
    }
}

private struct JSONBody {
    private enum SyntaxError: Error { case invalid }
    private enum State: UInt8 { case end, value, objectFirst, objectKey, colon, objectEnd, arrayFirst, arrayEnd }

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private var validStructure = true
    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    static func error(in body: Data) -> String? {
        guard String(data: body, encoding: .utf8) != nil else { return "invalid_json" }
        var parser = JSONBody(bytes: Array(body))
        do { return try parser.validate() }
        catch { return "invalid_json" }
    }

    private mutating func validate() throws -> String? {
        whitespace()
        let object = current == 123
        var states: [State] = [.end, .value]
        // Key equality preserves scalar sequences rather than Swift String's canonical equivalence.
        var objectKeys: [Set<[UInt8]>] = []
        // Foundation limits nesting and skips unknown numbers; validate syntax without either restriction.
        while let state = states.popLast() {
            whitespace()
            switch state {
            case .end:
                guard index == bytes.count else { throw SyntaxError.invalid }
            case .value:
                guard let byte = current else { throw SyntaxError.invalid }
                switch byte {
                case 123, 91:
                    index += 1
                    depth += 1
                    if depth > 64 { validStructure = false }
                    if byte == 123 { objectKeys.append([]) }
                    states.append(byte == 123 ? .objectFirst : .arrayFirst)
                case 34: try string()
                case 45, 48...57: try number()
                case 116: try literal("true")
                case 102: try literal("false")
                case 110: try literal("null")
                default: throw SyntaxError.invalid
                }
            case .objectFirst, .objectKey:
                if state == .objectFirst, current == 125 {
                    index += 1
                    depth -= 1
                    objectKeys.removeLast()
                } else {
                    let key = try string(isKey: true)
                    if !objectKeys[objectKeys.count - 1].insert(key).inserted { validStructure = false }
                    states.append(contentsOf: [.objectEnd, .value, .colon])
                }
            case .colon:
                guard current == 58 else { throw SyntaxError.invalid }
                index += 1
            case .objectEnd:
                if current == 125 {
                    index += 1
                    depth -= 1
                    objectKeys.removeLast()
                } else {
                    guard current == 44 else { throw SyntaxError.invalid }
                    index += 1
                    states.append(.objectKey)
                }
            case .arrayFirst:
                if current == 93 {
                    index += 1
                    depth -= 1
                } else {
                    states.append(contentsOf: [.arrayEnd, .value])
                }
            case .arrayEnd:
                if current == 93 {
                    index += 1
                    depth -= 1
                } else {
                    guard current == 44 else { throw SyntaxError.invalid }
                    index += 1
                    states.append(contentsOf: [.arrayEnd, .value])
                }
            }
        }
        return object && validStructure ? nil : "invalid_input"
    }

    private mutating func whitespace() {
        while let byte = current, byte == 32 || byte == 9 || byte == 10 || byte == 13 { index += 1 }
    }

    @discardableResult
    private mutating func string(isKey: Bool = false) throws -> [UInt8] {
        guard current == 34 else { throw SyntaxError.invalid }
        index += 1
        var key: [UInt8] = []
        var highSurrogate: UInt32?
        while let byte = current {
            index += 1
            switch byte {
            case 34:
                if highSurrogate != nil { validStructure = false }
                return key
            case 0...31: throw SyntaxError.invalid
            case 92:
                guard let escape = current else { throw SyntaxError.invalid }
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
                        guard let hex = current else { throw SyntaxError.invalid }
                        let digit: UInt32
                        switch hex {
                        case 48...57: digit = UInt32(hex - 48)
                        case 65...70: digit = UInt32(hex - 55)
                        case 97...102: digit = UInt32(hex - 87)
                        default: throw SyntaxError.invalid
                        }
                        scalar = scalar * 16 + digit
                        index += 1
                    }
                default: throw SyntaxError.invalid
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
                } else if isKey {
                    key.append(contentsOf: String(UnicodeScalar(scalar)!).utf8)
                }
            default:
                if highSurrogate != nil {
                    validStructure = false
                    highSurrogate = nil
                }
                if isKey { key.append(byte) }
            }
        }
        throw SyntaxError.invalid
    }

    private mutating func literal(_ value: String) throws {
        for byte in value.utf8 {
            guard current == byte else { throw SyntaxError.invalid }
            index += 1
        }
    }

    private mutating func digits() -> Bool {
        let start = index
        while let byte = current, (48...57).contains(byte) { index += 1 }
        return index > start
    }

    private mutating func number() throws {
        let start = index
        if current == 45 { index += 1 }
        if current == 48 { index += 1 }
        else {
            guard let first = current, (49...57).contains(first), digits() else { throw SyntaxError.invalid }
        }
        if current == 46 {
            index += 1
            guard digits() else { throw SyntaxError.invalid }
        }
        if current == 69 || current == 101 {
            index += 1
            if current == 43 || current == 45 { index += 1 }
            guard digits() else { throw SyntaxError.invalid }
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        if Double(token)?.isFinite != true { validStructure = false }
    }
}
