@_spi(Generated) import ChickinfryServer
import FoundationEssentials

private enum ProbeFailure: Error { case invalid }
private struct RawKeys: Decodable, Sendable {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    init(from decoder: any Decoder) throws {
        let object = try decoder.container(keyedBy: Key.self)
        if object.contains(Key(stringValue: "budget")) { throw _InputBudgetExceeded() }
        guard object.allKeys.map({ Array($0.stringValue.utf8) }) == [[195, 169], [101, 204, 129], [99, 97, 102, 101, 204, 129]],
              try object.decode(Int.self, forKey: Key(stringValue: "é")) == 1,
              try object.decode(Int.self, forKey: Key(stringValue: "e\u{0301}")) == 2,
              !object.contains(Key(stringValue: "café")) else { throw ProbeFailure.invalid }
    }
}
private struct Input: Decodable, Sendable { let mode: String; let value: String; let keys: RawKeys? }
private struct Output: Encodable, Sendable { let value: String; let setupCount: Int }
private struct Query: Encodable { let op = "query"; let sql: String; let params: [String] = [] }
private struct Rows: Decodable { struct Row: Decodable { let value: String }; let rows: [Row] }
private struct Environment: Decodable { let value: String }
private struct Lease: Decodable { let lease: UInt64 }
private actor SetupState {
    static let shared = SetupState()
    var count = 0
    func prepare() { count += 1 }
}
@MainActor private func mainActorValue(_ value: String) -> String { value }

@_cdecl("probe_boot")
public func probeBoot() {
    WasmServer.start(Application(operations: [Operation("probe.run", input: Input.self) { _, input in
        var value = input.value
        switch input.mode {
        case "legacy": try await Task.sleep(nanoseconds: 30_000_000)
        case "duration": try await Task.sleep(for: .milliseconds(30))
        case "main": _ = await mainActorValue(input.value)
        case "db", "cancel":
            guard let host = HostRequest.current else { throw OperationError.notImplemented }
            let result = try await host.database(JSONEncoder().encode(Query(sql: input.value)))
            value = try JSONDecoder().decode(Rows.self, from: result).rows[0].value
        case "env":
            guard let host = HostRequest.current else { throw OperationError.notImplemented }
            value = try JSONDecoder().decode(Environment.self, from: await host.environment("probe")).value
            try await host.log(level: "info", message: "Probe log")
        case "transaction":
            guard let host = HostRequest.current else { throw OperationError.notImplemented }
            let lease = try JSONDecoder().decode(Lease.self, from: await host.database(Data(#"{"op":"begin"}"#.utf8))).lease
            _ = try await host.database(Data("{\"op\":\"commit\",\"lease\":\(lease)}".utf8))
        default: break
        }
        return Output(value: value, setupCount: await SetupState.shared.count)
    }]), setup: {
        _ = try _decodeJSON(RawKeys.self, from: #"{"\u00e9":1,"e\u0301":2,"cafe\u0301":3}"#)
        for token in ["1e20", "-0", "9007199254740993", "9223372036854775807", "9223372036854775808", "1e-999", "4.9406564584124654e-324"] {
            guard (try? _decodeJSON(Int.self, from: token)) == (try? JSONDecoder().decode(Int.self, from: Data(token.utf8))),
                  (try? _decodeJSON(Int32.self, from: token)) == (try? JSONDecoder().decode(Int32.self, from: Data(token.utf8))),
                  (try? _decodeJSON(Int64.self, from: token)) == (try? JSONDecoder().decode(Int64.self, from: Data(token.utf8))),
                  (try? _decodeJSON(Double.self, from: token))?.bitPattern == (try? JSONDecoder().decode(Double.self, from: Data(token.utf8)))?.bitPattern
            else { throw ProbeFailure.invalid }
        }
        await SetupState.shared.prepare()
        return ApplicationOptions()
    })
}

@_cdecl("probe_handle")
public func probeHandle(_ call: Int32, _ metadata: UnsafePointer<UInt8>, _ metadataCount: Int32,
                        _ body: UnsafePointer<UInt8>, _ bodyCount: Int32) {
    WasmServer.handle(call, metadata: metadata, metadataCount: metadataCount, body: body, bodyCount: bodyCount)
}

@main private enum ServerProbe { static func main() {} }
