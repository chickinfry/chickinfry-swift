@_spi(Generated) import Chickinfry
import ChickinfryClientRequiredAuth

struct RequiredAuthBridge: Sendable {
    let client: ChickinfryClientRequiredAuth.Client
    init(_ transport: HTTPTransport) { client = ChickinfryClientRequiredAuth.createClient(transport: transport) }

    func call(_ operation: String, input: JSON) async throws -> [String: JSON] {
        let attempt = input["attempt"].string
        let email = input["email"].string
        switch operation {
        case "auth.signup":
            let result = try await client.auth.signup(.init(email: input.text("email"), password: input.text("password")))
            return ["accepted": .bool(result.accepted), "attempt": .string(result.attempt)]
        case "auth.send_verification_email":
            guard attempt == nil || email == nil else { throw ClientError.invalidArgument }
            let target: AuthSendVerificationEmailInputTargetChoice? = attempt.map { .attempt($0) } ?? email.map { .email($0) }
            let result = try await client.auth.sendVerificationEmail(.init(target: target))
            return ["accepted": .bool(result.accepted)]
        case "auth.verify_email":
            guard attempt == nil || email == nil else { throw ClientError.invalidArgument }
            let target: AuthVerifyEmailInputTargetChoice? = attempt.map { .attempt($0) } ?? email.map { .email($0) }
            let result = try await client.auth.verifyEmail(.init(code: input.text("code"), target: target))
            return session(result.accessToken, result.refreshToken, result.expiresAt, result.refreshExpiresAt,
                           result.userId, result.sessionId, result.emailVerified)
        case "auth.signin":
            let result = try await client.auth.signin(.init(email: input.text("email"), password: input.text("password")))
            return session(result.accessToken, result.refreshToken, result.expiresAt, result.refreshExpiresAt,
                           result.userId, result.sessionId, result.emailVerified)
        default: throw ProtocolFailure.unimplemented
        }
    }

    private func session(_ access: String, _ refresh: String, _ expires: String, _ refreshExpires: String,
                         _ user: String, _ session: String, _ verified: Bool) -> [String: JSON] {
        ["access_token": .string(access), "refresh_token": .string(refresh), "expires_at": .string(expires),
         "refresh_expires_at": .string(refreshExpires), "user_id": .string(user), "session_id": .string(session),
         "email_verified": .bool(verified)]
    }
}
