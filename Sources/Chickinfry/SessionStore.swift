import Foundation

/// An immutable session. Timestamps retain the server's original precision.
public struct SessionRecord: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var deviceGeneration: UInt64?
    var deviceAuthGeneration: UInt64?
    var deviceRefreshRequestID: String?
    /// The service origin this session authenticates against.
    public let origin: String
    /// The credential sent as the bearer token on protected requests.
    public let accessToken: String
    /// The credential exchanged for a new access token during refresh.
    public let refreshToken: String
    /// When the access token expires.
    public let expiresAt: String
    /// When the refresh token expires.
    public let refreshExpiresAt: String
    /// The signed-in user's identifier issued with the session.
    public let userID: String
    /// The identifier of this sign-in session.
    public let sessionID: String

    /// Validates the origin, credentials, and required fields without changing timestamp precision.
    public init(origin: String, accessToken: String, refreshToken: String, expiresAt: String,
                refreshExpiresAt: String, userID: String, sessionID: String) throws {
        self.origin = try ClientTransport.validateOrigin(origin)
        try ClientTransport.validateToken(accessToken)
        try ClientTransport.validateToken(refreshToken)
        guard !expiresAt.isEmpty, !refreshExpiresAt.isEmpty, !userID.isEmpty, !sessionID.isEmpty else {
            throw OperationError(code: "invalid_input", status: nil)
        }
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshExpiresAt = refreshExpiresAt
        self.userID = userID
        self.sessionID = sessionID
    }

    public var description: String { "SessionRecord" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>(), displayStyle: .struct)
    }

    var credential: SessionCredential {
        SessionCredential(origin: origin, access: accessToken, refresh: refreshToken)
    }
}

struct SessionCredential: Hashable, Sendable {
    let origin: String
    let access: String
    let refresh: String
}

/// Wrappers of one physical record must share a coordinator and atomic conditional writes.
/// Conditional writes compare the captured origin and both tokens atomically.
/// Device adapters also compare the generation captured by load().
/// Storage failures must throw; they must never be reported as an absent session or a mismatch.
public protocol SessionStore: AnyObject, Sendable {
    /// The single origin this store is bound to; records from other origins must not be stored.
    var origin: String { get }
    /// Must return the same instance over one physical record; creating a new coordinator per access is not allowed.
    var coordinator: SessionCoordinator { get }
    /// Returns nil only when no record is stored; read failures throw.
    func load() async throws -> SessionRecord?
    /// Makes the record available before returning; write failures throw.
    func save(_ session: SessionRecord) async throws
    /// Returns true after replacement, false on a stale captured record or absence; write failures throw.
    func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool
    /// Returns true after removal, false on a stale captured record or absence; deletion failures throw.
    func clear(ifMatching expected: SessionRecord) async throws -> Bool
}

func sessionStoreCall<Value: Sendable>(
    _ operation: @Sendable () async throws -> Value
) async throws -> Value {
    do { return try await operation() }
    catch let error as OperationError where DeviceLimits.errorCodes.contains(error.code) { throw error }
    catch { throw OperationError(code: "session_store_error", status: nil) }
}

protocol DeviceRefreshing: SessionStore {
    func beginRefresh(ifMatching expected: SessionRecord, requestID: String) async throws -> Bool
    func refreshCandidate(ifMatching expected: SessionRecord) async throws -> SessionRecord?
}

protocol DeviceAuthenticationStore: SessionStore {
    func recover(_ recovery: DeviceRecovery, observing snapshot: DeviceSnapshot) async throws -> DeviceRecoveryResult
    func snapshot() async throws -> DeviceSnapshot
    func snapshot(preparingAuthentication: Bool) async throws -> DeviceSnapshot
    func rejectAuthentication(_ before: DeviceSnapshot) async throws
    func install(_ session: SessionRecord, consumingEmail: String?, ifGeneration: UInt64,
                 authGeneration: UInt64?) async throws -> Bool
    func discardAttempt(_ attempt: DeviceAttempt, ifGeneration: UInt64) async throws -> Bool
}

func loadSession(_ store: any SessionStore, origin: String) async throws -> SessionRecord? {
    let session = try await store.coordinator.current(store: store)
    guard store.origin == origin, session == nil || session?.origin == origin else {
        throw OperationError(code: "session_store_error", status: nil)
    }
    return session
}
