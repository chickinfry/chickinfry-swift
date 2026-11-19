#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct Storage: Sendable {
    private static let byteLimit = 4 << 20
    let name: String
    let host: HostRequest?

    public func get(_ key: String) async throws -> Data? {
        let frame = try await call(["op": .string("get"), "key": .string(key)])
        if frame["value"] == .null { return nil }
        guard case .string(let encoded) = frame["value"], let bytes = Data(base64Encoded: encoded),
              bytes.count <= Self.byteLimit else {
            throw OperationError(code: "operation_failed", status: 500)
        }
        return bytes
    }

    public func put(_ key: String, _ bytes: Data, _ contentType: String) async throws {
        guard bytes.count <= Self.byteLimit else { throw OperationError(code: "operation_failed", status: 500) }
        _ = try await call([
            "op": .string("put"), "key": .string(key),
            "bytes": .string(bytes.base64EncodedString()), "contentType": .string(contentType),
        ])
    }

    private func call(_ frame: [String: HostValue]) async throws -> [String: HostValue] {
        try Task.checkCancellation()
        guard let host else { throw OperationError(code: "service_unavailable", status: 503) }
        var request = frame
        request["name"] = .string(name)
        do {
            let response = try await host.storage(request)
            try Task.checkCancellation()
            return try HostFrame.decode(response)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as HostFailure where error.code == "service_unavailable" {
            throw OperationError(code: "service_unavailable", status: 503)
        } catch {
            throw OperationError(code: "operation_failed", status: 500)
        }
    }
}
