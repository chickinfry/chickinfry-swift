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
        guard (try? JSONDecoder().decode(JSONObject.self, from: body)) != nil else {
            return .failure("invalid_input", status: 400)
        }
        return await target.invoke(body, context)
    }
}

private struct JSONObject: Decodable {
    init(from decoder: any Decoder) throws { _ = try decoder.container(keyedBy: Key.self) }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
}
