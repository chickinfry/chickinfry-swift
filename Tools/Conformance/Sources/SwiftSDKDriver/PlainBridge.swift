import Chickinfry
import ChickinfryClientPlain

struct PlainBridge: Sendable {
    let client: ChickinfryClientPlain.Client
    init(_ transport: HTTPTransport) { client = ChickinfryClientPlain.createClient(transport: transport) }

    func call(_ operation: String, input: JSON) async throws -> [String: JSON] {
        switch operation {
        case "probe.echo":
            let result = try await client.probe.echo(.init(wireValue: input.text("wire_value")))
            return ["wire_value": .string(result.wireValue), "observed_at": .string(result.observedAt)]
        case "probe.identify":
            let result = try await client.probe.identify(.init(id: input.text("id")))
            return ["id": .string(result.id)]
        case "probe.list":
            let result = try await client.probe.list(.init())
            return ["rows": .array(result.rows.map {
                .object(["id": .string($0.id), "wire_value": .string($0.wireValue), "observed_at": .string($0.observedAt)])
            })]
        default: throw ProtocolFailure.unimplemented
        }
    }
}
