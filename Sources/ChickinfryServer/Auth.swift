#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct AuthSession: Codable, Equatable, Sendable {
    public struct User: Codable, Equatable, Sendable {
        public let id: String
        public let email: String
    }

    public let id: String
    public let user: User
}

public struct AuthenticatedContext<SessionValue: Sendable>: Sendable {
    public struct Auth: Sendable {
        public let session: SessionValue
    }

    @_spi(Generated) public let base: Context
    public let auth: Auth
    public var request: Context.Request { base.request }

    init(_ base: Context, session: SessionValue) {
        self.base = base
        self.auth = Auth(session: session)
    }

    public func log(level: String, message: String, fields: [String: LogValue]? = nil) async {
        await base.log(level: level, message: message, fields: fields)
    }
}

struct RequestAuth: Sendable {
    let session: AuthSession?

    init(_ value: JSONValue) throws {
        guard case .object(let members, let indices) = value, members.count == 2,
              let version = indices[Array("version".utf8)], case .number("1") = members[version].value,
              let session = indices[Array("session".utf8)] else { throw HostFailure.invalidFrame }

        switch members[session].value {
        case .null:
            self.session = nil
        case .object(let fields, let keys) where fields.count == 2:
            guard let id = keys[Array("id".utf8)], case .string(let sessionID) = fields[id].value, !sessionID.isEmpty,
                  let user = keys[Array("user".utf8)], case .object(let fields, let keys) = fields[user].value,
                  fields.count == 2,
                  let id = keys[Array("id".utf8)], case .string(let userID) = fields[id].value, !userID.isEmpty,
                  let email = keys[Array("email".utf8)], case .string(let address) = fields[email].value, !address.isEmpty
            else { throw HostFailure.invalidFrame }
            self.session = AuthSession(id: sessionID, user: .init(id: userID, email: address))
        default:
            throw HostFailure.invalidFrame
        }
    }
}

struct RequestMetadata: Sendable {
    static let byteLimit = 4 << 20

    let operation: String
    let context: Context
    let rid: UInt64?
    let deadlineMilliseconds: UInt64?
    let auth: RequestAuth?

    init(_ data: Data) throws {
        guard data.count <= Self.byteLimit else { throw HostFailure.invalidFrame }
        enum Key: String, CodingKey { case operation, context, rid, deadlineMilliseconds }
        let value = try JSONBody.parse(data)
        guard case .object(let members, let indices) = value else { throw HostFailure.invalidFrame }
        let frame = try JSONValueDecoder(value).container(keyedBy: Key.self)
        operation = try frame.decode(String.self, forKey: .operation)
        context = try frame.decode(Context.self, forKey: .context)
        rid = try frame.decodeIfPresent(UInt64.self, forKey: .rid)
        deadlineMilliseconds = try frame.decodeIfPresent(UInt64.self, forKey: .deadlineMilliseconds)
        auth = try indices[Array("auth".utf8)].map { try RequestAuth(members[$0].value) }
        guard auth == nil || rid != nil else { throw HostFailure.invalidFrame }
    }
}
