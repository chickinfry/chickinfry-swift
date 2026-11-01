import Chickinfry
import ChickinfryClientAuth

struct AuthBridge: Sendable {
    let client: ChickinfryClientAuth.Client
    init(_ transport: HTTPTransport) { client = ChickinfryClientAuth.createClient(transport: transport) }

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
        case "auth.signin":
            let result = try await client.auth.signin(.init(email: input.text("email"), password: input.text("password")))
            return session(result.accessToken, result.refreshToken, result.expiresAt,
                           result.refreshExpiresAt, result.userId, result.sessionId)
        case "auth.signup":
            let result = try await client.auth.signup(.init(email: input.text("email"), password: input.text("password")))
            return session(result.accessToken, result.refreshToken, result.expiresAt,
                           result.refreshExpiresAt, result.userId, result.sessionId)
        case "auth.refresh":
            let result = try await client.auth.refresh(.init(refreshToken: input.text("refresh_token")))
            return session(result.accessToken, result.refreshToken, result.expiresAt,
                           result.refreshExpiresAt, result.userId, result.sessionId)
        case "auth.logout":
            let result = try await client.auth.logout(.init())
            return ["status": .string(result.status)]
        case "auth.session":
            let result = try await client.auth.session(.init())
            return ["email": .string(result.email), "id": .string(result.id), "session_id": .string(result.sessionId)]
        default: throw ProtocolFailure.unimplemented
        }
    }

    private func session(_ access: String, _ refresh: String, _ expires: String,
                         _ refreshExpires: String, _ user: String, _ session: String) -> [String: JSON] {
        ["access_token": .string(access), "refresh_token": .string(refresh),
         "expires_at": .string(expires), "refresh_expires_at": .string(refreshExpires),
         "user_id": .string(user), "session_id": .string(session)]
    }
}
