import Chickinfry
import ChickinfryClientEmptySession

struct EmptySessionBridge: Sendable {
    let client: ChickinfryClientEmptySession.Client

    init(_ transport: HTTPTransport) { client = ChickinfryClientEmptySession.createClient(transport: transport) }

    func call(_ operation: String, input: JSON) async throws -> [String: JSON] {
        switch operation {
        case "auth.signin":
            let result = try await client.auth.signin(.init(email: input.text("email"), password: input.text("password")))
            return ["session_id": .string(result.sessionId)]
        case "auth.logout":
            let result = try await client.auth.logout(.init())
            return ["status": .string(result.status)]
        case "probe.echo":
            let result = try await client.probe.echo(.init(wireValue: input.text("wire_value")))
            return ["wire_value": .string(result.wireValue), "observed_at": .string(result.observedAt)]
        case "probe.list":
            let result = try await client.probe.list(.init())
            return ["rows": .array(result.rows.map {
                .object(["id": .string($0.id), "wire_value": .string($0.wireValue), "observed_at": .string($0.observedAt)])
            })]
        default: throw ProtocolFailure.unimplemented
        }
    }
}
