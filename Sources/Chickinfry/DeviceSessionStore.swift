import Foundation

/// Omit this setting to use the application's device storage.
public enum Persist: Sendable {
    /// Keep authentication state only for this run.
    case disabled
    /// Use an absolute, private application state directory.
    case dir(String)
}

private func resolvedPersistence(_ value: Persist?) throws -> Persist? {
    guard case .some(.dir(let path)) = value else { return value }
    guard !path.isEmpty, !path.contains("\0") else { throw deviceError() }
    let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return .dir(URL(fileURLWithPath: path, relativeTo: base).absoluteURL.path)
}

private func deviceStateRoot(_ persist: Persist?) throws -> String {
    if case .some(.dir(let path)) = persist { return path }
    #if os(Linux)
    if let xdg = ProcessInfo.processInfo.environment["XDG_STATE_HOME"], xdg.hasPrefix("/") {
        return xdg + "/chickinfry"
    }
    return FileManager.default.homeDirectoryForCurrentUser.path + "/.local/state/chickinfry"
    #else
    guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        throw deviceError()
    }
    return support.resolvingSymlinksInPath().appendingPathComponent("chickinfry").path
    #endif
}

struct DeviceScope: Codable, Equatable, Sendable {
    let origin: String
    let app: String
    let project: String
    let environment: String
}

func validDeviceComponent(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 128 && value != "." && value != ".."
        && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0)
            || (48...57).contains($0) || [45, 46, 95].contains($0) }
}

@_spi(DeviceStorage)
public struct DeviceSnapshot: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let generation: UInt64
    public var authGeneration: UInt64
    let localAuthGeneration: UInt64
    public var session: SessionRecord?
    public let attempts: [DeviceAttempt]
    var userID: String?
    var sessionID: String?
    var authenticationSwitchID: String?
    let state: DeviceState
    public var description: String { "DeviceSnapshot" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

@_spi(DeviceStorage)
public struct DeviceAttempt: Codable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let id: String
    public let email: String
    public let screen: String
    public let acceptedAt: String
    public let expiresAt: String
    let sequence: UInt64
    public var description: String { "DeviceAttempt" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }

    func expiry() throws -> Int64 {
        min(try deviceTimestamp(expiresAt), try deviceTimestamp(acceptedAt) + DeviceLimits.attemptLifetime)
    }

    func validate() throws {
        guard id.utf8.count == DeviceLimits.identifierBytes, UUID(uuidString: id) != nil,
              !email.isEmpty, email.count <= DeviceLimits.emailCharacters,
              !email.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !screen.isEmpty, screen.utf8.count <= DeviceLimits.screenBytes,
              screen.utf8.allSatisfy({ (33...126).contains($0) }),
              try deviceTimestamp(expiresAt) > deviceTimestamp(acceptedAt) else {
            throw deviceError("device_storage_corrupt")
        }
    }
}

struct StoredSession: Codable, Equatable, Sendable {
    let origin: String
    let accessToken: String
    let refreshToken: String
    let expiresAt: String
    let refreshExpiresAt: String
    let userID: String
    let sessionID: String

    init(_ value: SessionRecord) {
        origin = value.origin; accessToken = value.accessToken; refreshToken = value.refreshToken
        expiresAt = value.expiresAt; refreshExpiresAt = value.refreshExpiresAt
        userID = value.userID; sessionID = value.sessionID
    }

    func restore(generation: UInt64, authGeneration: UInt64? = nil) throws -> SessionRecord {
        guard userID.utf8.count == DeviceLimits.identifierBytes, UUID(uuidString: userID) != nil,
              sessionID.utf8.count == DeviceLimits.identifierBytes, UUID(uuidString: sessionID) != nil else {
            throw deviceError("device_storage_corrupt")
        }
        var value = try SessionRecord(origin: origin, accessToken: accessToken, refreshToken: refreshToken,
                                      expiresAt: expiresAt, refreshExpiresAt: refreshExpiresAt,
                                      userID: userID, sessionID: sessionID)
        value.deviceGeneration = generation
        value.deviceAuthGeneration = authGeneration
        return value
    }
}

struct DeviceState: Codable, Sendable {
    struct AuthenticationSwitch: Codable, Equatable, Sendable { let id: String; let generation: UInt64 }
    var version = 1
    let scope: DeviceScope
    let installation: String?
    var generation: UInt64 = 0
    var authGeneration: UInt64 = 0
    var authenticationSwitches: [AuthenticationSwitch] = []
    var session: StoredSession?
    var attempts: [DeviceAttempt] = []
    var refreshUncertain = false
    var refreshRequestID: String?
    var observedAt: Int64 = 0

    mutating func advance() throws {
        guard generation < UInt64.max else { throw deviceError("device_storage_full") }
        generation += 1
    }

    mutating func advanceAuthentication(after floor: UInt64 = 0) throws {
        let current = max(authGeneration, floor)
        guard current < UInt64.max else { throw deviceError("device_storage_full") }
        authGeneration = current + 1
    }

    mutating func prune(now: Int64) throws {
        let time = max(observedAt, now)
        attempts = try attempts.filter { try $0.expiry() > time }
        observedAt = time
    }

    func validatePayload() throws {
        guard attempts.count <= DeviceLimits.attempts else { throw deviceError("device_storage_full") }
        guard observedAt >= 0, session != nil || !refreshUncertain,
              session?.origin == nil || session?.origin == scope.origin,
              Set(attempts.map(\.screen)).count == attempts.count else { throw deviceError("device_storage_corrupt") }
        if let refreshRequestID {
            guard refreshUncertain, UUID(uuidString: refreshRequestID) != nil else { throw deviceError("device_storage_corrupt") }
        }
        guard Set(authenticationSwitches.map(\.id)).count == authenticationSwitches.count,
              authenticationSwitches.allSatisfy({ UUID(uuidString: $0.id) != nil && $0.generation <= authGeneration }) else {
            throw deviceError("device_storage_corrupt")
        }
        for attempt in attempts { try attempt.validate() }
        do { _ = try session?.restore(generation: generation) }
        catch { throw deviceError("device_storage_corrupt") }
    }

    func encoded() throws -> Data {
        try validatePayload()
        guard installation != nil else { throw deviceError("device_storage_corrupt") }
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count <= DeviceLimits.bundleBytes else { throw deviceError("device_storage_full") }
        return bytes
    }
}

private struct DeviceIdentity: Codable {
    let installation: String
    let backend: String
}

private final class DeviceContext: @unchecked Sendable {
    let coordinator = SessionCoordinator()
    private let lock = NSLock()
    private var blocked: ClientError?
    private var installation: String?
    private var liveSwitches: Set<String> = []
    func check() throws { try lock.withLock { if let blocked { throw blocked } } }
    func block(_ error: ClientError) {
        var blockedError = error
        blockedError.devicePreparation = true
        lock.withLock { blocked = blockedError }
    }
    func bindInstallation(_ value: String) -> Bool {
        lock.withLock {
            let changed = installation != nil && installation != value
            installation = value
            return changed
        }
    }
    func rememberSwitch(_ id: String) { lock.withLock { _ = liveSwitches.insert(id) } }
    func knowsSwitch(_ id: String) -> Bool { lock.withLock { liveSwitches.contains(id) } }
    func forgetSwitch(_ id: String) { lock.withLock { _ = liveSwitches.remove(id) } }
}

private final class DeviceContexts: @unchecked Sendable {
    static let shared = DeviceContexts()
    private let lock = NSLock()
    private var values: [String: DeviceContext] = [:]
    func context(_ key: String) -> DeviceContext {
        lock.withLock {
            if let existing = values[key] { return existing }
            let value = DeviceContext()
            values[key] = value
            return value
        }
    }
}

@_spi(DeviceStorage)
public actor DeviceSessionStore: SessionStore, DeviceRefreshing, DeviceAuthenticationStore, CustomStringConvertible,
                                 CustomDebugStringConvertible, CustomReflectable {
    public nonisolated let origin: String
    public nonisolated let coordinator: SessionCoordinator
    private let scope: DeviceScope
    private let persist: Persist?
    private let context: DeviceContext
    private let keychainCalls: (any DeviceKeychainCalls)?
    private let usesKeychain: Bool
    private var memory: DeviceState
    private var boundInstallation: String?
    private var rejoinSwitches: Set<String> = []
    private var rejoinAuthGeneration: UInt64?

    public init(origin: String, app: String, project: String, environment: String, persist: Persist? = nil) throws {
        try self.init(origin: origin, app: app, project: project, environment: environment,
                      persist: persist, keychainCalls: nil)
    }

    init(origin: String, app: String, project: String, environment: String, persist: Persist?,
         keychainCalls: (any DeviceKeychainCalls)?, protected: Bool? = nil) throws {
        self.origin = try HTTPTransport.validateOrigin(origin)
        for component in [app, project, environment] {
            guard validDeviceComponent(component) else {
                throw ClientError(code: "invalid_input", status: nil)
            }
        }
        scope = DeviceScope(origin: self.origin, app: app, project: project, environment: environment)
        self.persist = try resolvedPersistence(persist)
        #if os(iOS)
        if case .some(.dir(_)) = persist { throw deviceError() }
        #endif
        self.keychainCalls = keychainCalls
        #if os(macOS)
        usesKeychain = protected ?? false
        #elseif canImport(Security)
        usesKeychain = true
        #else
        usesKeychain = false
        #endif
        memory = DeviceState(scope: scope, installation: UUID().uuidString)
        if case .some(.disabled) = self.persist {
            context = DeviceContext()
        } else {
            let root = try deviceStateRoot(self.persist)
            guard root.hasPrefix("/"), !root.contains("\0") else { throw deviceError() }
            let base = URL(fileURLWithPath: root).standardizedFileURL.path
            context = DeviceContexts.shared.context([base, app, project, environment, self.origin].joined(separator: "\0"))
        }
        coordinator = context.coordinator
        if case .some(.disabled) = self.persist {} else {
            if case .some(.dir(let path)) = self.persist { _ = try DeviceFiles(path: path, baseDirectory: true) }
            _ = try DeviceFiles(path: location())
        }
    }

    public func snapshot() async throws -> DeviceSnapshot {
        try await snapshot(preparingAuthentication: false)
    }

    public func snapshot(preparingAuthentication: Bool) async throws -> DeviceSnapshot {
        do {
        let floor = await coordinator.authenticationGenerationFloor()
        let prepared = try transaction { state in
            var changed = false
            let clearsPeer = preparingAuthentication && (recoveryBlocked(state)
                || state.authenticationSwitches.contains(where: { !context.knowsSwitch($0.id) }))
            if clearsPeer {
                state.session = nil
                state.authenticationSwitches = []
                state.refreshUncertain = false
                state.refreshRequestID = nil
                try state.advanceAuthentication(after: floor)
                try state.advance()
                changed = true
            }
            var switchID: String?
            if preparingAuthentication, state.session != nil {
                switchID = UUID().uuidString
                state.authenticationSwitches.append(.init(id: switchID!, generation: state.authGeneration))
                try state.advance()
                changed = true
            }
            return ((state: state, switchID: switchID, clearsPeer: clearsPeer), changed)
        }
        if prepared.clearsPeer {
            rejoinSwitches = []
            rejoinAuthGeneration = nil
            await coordinator.discardVolatileSession()
        }
        let snapshot = try snapshotValue(prepared.state, switchID: prepared.switchID)
        if let id = snapshot.authenticationSwitchID { context.rememberSwitch(id) }
        return try await coordinator.authenticationSnapshot(snapshot, store: self)
        } catch {
            guard preparingAuthentication else { throw error }
            if let error = error as? ClientError,
               error.reason == "device_storage_corrupt" || error.reason == "device_storage_version_unsupported" { throw error }
            var failure = deviceError()
            failure.devicePreparation = true
            throw failure
        }
    }

    public func rejectAuthentication(_ before: DeviceSnapshot) async throws {
        guard let id = before.authenticationSwitchID else { return }
        try transaction { state in
            guard state.authGeneration == before.authGeneration,
                  state.authenticationSwitches.contains(where: { $0.id == id }) else { return ((), false) }
            state.authenticationSwitches.removeAll { $0.id == id }
            try state.advance()
            return ((), true)
        }
        context.forgetSwitch(id)
    }

    func prepareInstallation() async throws {
        guard usesKeychain else { return }
        if case .some(.disabled) = persist { return }
        #if canImport(Security)
        let appFiles = try DeviceFiles(path: appLocation())
        let changed = try appFiles.locked { try establishInstallation(appFiles).changed }
        if changed { await coordinator.discardVolatileSession() }
        #endif
    }

    #if canImport(Security)
    private func establishInstallation(_ files: DeviceFiles) throws -> (id: String, changed: Bool) {
        let id = try DeviceInstallation(app: scope.app, files: files,
                                         calls: keychainCalls ?? SystemDeviceKeychainCalls()).prepare()
        guard boundInstallation == nil || boundInstallation == id else {
            throw ClientError(code: "session_changed", status: nil)
        }
        boundInstallation = id
        return (id, context.bindInstallation(id))
    }
    #endif

    public func load() async throws -> SessionRecord? {
        try load(rejectBlocked: false)
    }

    func loadForInvocation() throws -> SessionRecord? {
        try load(rejectBlocked: true)
    }

    private func load(rejectBlocked: Bool) throws -> SessionRecord? {
        try transaction { state in
            if recoveryBlocked(state) {
                if rejectBlocked { throw ClientError(code: "invalid_token", status: 401) }
                return (nil, false)
            }
            if state.authenticationSwitches.contains(where: { !context.knowsSwitch($0.id) }) {
                state.session = nil
                state.authenticationSwitches = []
                state.refreshUncertain = false
                state.refreshRequestID = nil
                try state.advanceAuthentication()
                try state.advance()
                return (nil, true)
            }
            guard !state.refreshUncertain else { throw ClientError(code: "invalid_token", status: 401) }
            return (try state.session?.restore(generation: state.generation, authGeneration: state.authGeneration), false)
        }
    }

    private func recoveryBlocked(_ state: DeviceState) -> Bool {
        if rejoinAuthGeneration != state.authGeneration { rejoinSwitches = [] }
        rejoinSwitches.formIntersection(state.authenticationSwitches.map(\.id))
        if rejoinSwitches.isEmpty { rejoinAuthGeneration = nil }
        return !rejoinSwitches.isEmpty
    }

    private func snapshotValue(_ state: DeviceState, switchID: String? = nil) throws -> DeviceSnapshot {
        let blocked = recoveryBlocked(state)
        let session = state.refreshUncertain || blocked ? nil
            : try state.session?.restore(generation: state.generation, authGeneration: state.authGeneration)
        return DeviceSnapshot(generation: state.generation, authGeneration: state.authGeneration,
                              localAuthGeneration: state.authGeneration, session: session, attempts: state.attempts,
                              userID: state.session?.userID, sessionID: state.session?.sessionID,
                              authenticationSwitchID: switchID, state: state)
    }

    func recover(_ recovery: DeviceRecovery, observing snapshot: DeviceSnapshot) async throws -> DeviceRecoveryResult {
        var pending = recovery
        var observed = snapshot
        func applied(_ state: DeviceState) -> Bool {
            state.authGeneration == pending.writtenAuthGeneration && state.session == StoredSession(pending.writtenSession)
                && !state.refreshUncertain
                && !state.authenticationSwitches.contains(where: { $0.id == pending.before.authenticationSwitchID })
        }
        func classify(_ state: DeviceState) -> Bool {
            let base = pending.before.state
            guard state.scope == base.scope, state.installation == base.installation,
                  applied(state) || state.authGeneration == base.authGeneration else { return false }
            if !applied(state) {
                let switchID = pending.before.authenticationSwitchID
                let ownsSwitch = switchID == nil || state.authenticationSwitches.contains(where: { $0.id == switchID })
                let ownsAttempt = pending.consuming == nil || state.attempts.contains(where: {
                    $0.id == pending.consuming?.id && $0.screen == pending.consuming?.screen
                })
                let ownsRefresh = !pending.ownsRefresh || (pending.refreshRequestID != nil
                    && state.refreshRequestID == pending.refreshRequestID)
                let sameRefresh = pending.ownsRefresh || state.refreshRequestID == base.refreshRequestID
                if state.session != base.session || state.refreshUncertain != (pending.ownsRefresh || base.refreshUncertain)
                    || !ownsSwitch || !ownsAttempt
                    || !ownsRefresh || !sameRefresh {
                    pending.installsSession = false
                }
            }
            let peers = state.authenticationSwitches.filter { $0.id != pending.before.authenticationSwitchID }
            rejoinSwitches = Set(peers.map(\.id))
            rejoinAuthGeneration = state.authGeneration
            return true
        }
        guard classify(snapshot.state) else { return .stale(snapshot) }
        do {
            return try transaction { state in
                observed = try snapshotValue(state)
                guard classify(state) else { return (.stale(observed), false) }
                observed = try snapshotValue(state)
                let reflected = applied(state)
                let sameSession = state.session == StoredSession(pending.session)
                let consumes = pending.consumingEmail.map { email in state.attempts.contains { $0.email == email } } ?? false
                if pending.installsSession, recoveryBlocked(state), !(reflected && sameSession) {
                    return (.memory(observed, blocked: true, recovery: pending), false)
                }
                if !pending.installsSession && !consumes { return (.stale(observed), false) }
                if reflected && sameSession && !consumes { return (.settled(observed), false) }
                if pending.installsSession {
                    if reflected {
                        // Rebase only after the complete credential transition proves our previous write applied.
                        pending.before = observed
                        pending.ownsRefresh = false
                        pending.consuming = nil
                        pending.consumingEmail = nil
                    }
                    state.authGeneration = pending.authGeneration
                    state.session = StoredSession(pending.session)
                    state.refreshUncertain = false
                    state.refreshRequestID = nil
                    state.authenticationSwitches.removeAll { $0.id == pending.before.authenticationSwitchID }
                    pending.writtenSession = pending.session
                    pending.writtenAuthGeneration = pending.authGeneration
                }
                // Only consumption changes attempts locally; preserve peer additions and deletions.
                if let email = recovery.consumingEmail { state.attempts.removeAll { $0.email == email } }
                try state.advance()
                try state.prune(now: Int64(Date().timeIntervalSince1970))
                return (.settled(try snapshotValue(state)), true)
            }
        } catch let error as ClientError
            where error.reason == "device_storage_unavailable" || error.reason == "device_storage_full" {
            let blocked = !pending.installsSession || recoveryBlocked(observed.state)
                || (observed.state.refreshUncertain && !pending.ownsRefresh)
            return .memory(observed, blocked: blocked, recovery: pending)
        }
    }

    public func save(_ session: SessionRecord) async throws {
        guard session.origin == origin else { throw ClientError(code: "origin_mismatch", status: nil) }
        try transaction { state in
            if state.session?.sessionID != session.sessionID { try state.advanceAuthentication() }
            try state.advance()
            state.session = StoredSession(session)
            state.authenticationSwitches = []
            state.refreshUncertain = false
            state.refreshRequestID = nil
            return ((), true)
        }
        await coordinator.discardVolatileSession()
    }

    public func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool {
        guard session.origin == origin else { throw ClientError(code: "origin_mismatch", status: nil) }
        let replaced = try transaction { state in
            guard try matches(state, expected) else { return (false, false) }
            if state.session?.sessionID != session.sessionID { try state.advanceAuthentication() }
            try state.advance()
            state.session = StoredSession(session)
            state.refreshUncertain = false
            state.refreshRequestID = nil
            return (true, true)
        }
        if replaced { await coordinator.discardVolatileSession() }
        return replaced
    }

    public func clear(ifMatching expected: SessionRecord) async throws -> Bool {
        let floor = await coordinator.authenticationGenerationFloor()
        do {
            let removed = try transaction { state in
                guard try matches(state, expected) else { return (false, false) }
                try state.advanceAuthentication(after: floor)
                try state.advance()
                state.session = nil
                state.authenticationSwitches = []
                state.refreshUncertain = false
                state.refreshRequestID = nil
                return (true, true)
            }
            if removed { await coordinator.discardVolatileSession() }
            return removed
        } catch let error as ClientError {
            context.block(error)
            await coordinator.discardVolatileSession()
            throw error
        }
    }

    public func beginRefresh(ifMatching expected: SessionRecord) async throws -> Bool {
        try await beginRefresh(ifMatching: expected, requestID: UUID().uuidString)
    }

    func beginRefresh(ifMatching expected: SessionRecord, requestID: String) async throws -> Bool {
        try transaction { state in
            guard !state.refreshUncertain, try matches(state, expected) else { return (false, false) }
            state.refreshUncertain = true
            state.refreshRequestID = requestID
            return (true, true)
        }
    }

    func refreshCandidate(ifMatching expected: SessionRecord) async throws -> SessionRecord? {
        try transaction { state in
            guard state.refreshUncertain, state.authGeneration == expected.deviceAuthGeneration,
                  let requestID = expected.deviceRefreshRequestID, state.refreshRequestID == requestID,
                  let current = try state.session?.restore(generation: state.generation, authGeneration: state.authGeneration),
                  current.credential == expected.credential else { return (nil, false) }
            var candidate = current
            candidate.deviceRefreshRequestID = requestID
            return (candidate, false)
        }
    }

    public func install(_ session: SessionRecord, consumingEmail: String?, ifGeneration: UInt64,
                        authGeneration: UInt64? = nil) async throws -> Bool {
        guard session.origin == origin else { throw ClientError(code: "origin_mismatch", status: nil) }
        let installed = try transaction { state in
            guard state.generation == ifGeneration else { return (false, false) }
            if let authGeneration {
                guard authGeneration >= state.authGeneration else { return (false, false) }
                state.authGeneration = authGeneration
            } else if state.session?.sessionID != session.sessionID {
                try state.advanceAuthentication()
            }
            try state.advance()
            state.session = StoredSession(session)
            state.authenticationSwitches = []
            state.refreshUncertain = false
            state.refreshRequestID = nil
            if let consumingEmail { state.attempts.removeAll { $0.email == consumingEmail } }
            return (true, true)
        }
        if installed { await coordinator.discardVolatileSession() }
        return installed
    }

    public func logout(ifGeneration: UInt64) async throws -> Bool {
        let floor = await coordinator.authenticationGenerationFloor()
        do {
            let removed = try transaction { state in
                guard state.generation == ifGeneration else { return (false, false) }
                try state.advanceAuthentication(after: floor)
                try state.advance()
                state.session = nil
                state.authenticationSwitches = []
                state.attempts = []
                state.refreshUncertain = false
                state.refreshRequestID = nil
                return (true, true)
            }
            if removed { await coordinator.discardVolatileSession() }
            return removed
        } catch let error as ClientError {
            context.block(error)
            await coordinator.discardVolatileSession()
            throw error
        }
    }

    public func saveAttempt(id: String, email: String, screen: String, acceptedAt: String,
                            expiresAt: String, ifGeneration: UInt64) async throws -> Bool {
        try transaction { state in
            guard state.generation == ifGeneration else { return (false, false) }
            try state.prune(now: Int64(Date().timeIntervalSince1970))
            try state.advance()
            let attempt = DeviceAttempt(id: id, email: email, screen: screen, acceptedAt: acceptedAt,
                                        expiresAt: expiresAt, sequence: state.generation)
            try attempt.validate()
            state.attempts.removeAll { $0.screen == screen }
            state.attempts.append(attempt)
            return (true, true)
        }
    }

    public func discardAttempt(_ attempt: DeviceAttempt, ifGeneration: UInt64) async throws -> Bool {
        try transaction { state in
            guard state.generation == ifGeneration else { return (false, false) }
            guard let index = state.attempts.firstIndex(where: { $0.id == attempt.id && $0.screen == attempt.screen }) else {
                return (true, false)
            }
            state.attempts.remove(at: index)
            try state.advance()
            return (true, true)
        }
    }

    public func attempt(screen: String, now: Date = Date()) async throws -> DeviceAttempt? {
        try transaction { state in
            let time = Int64(now.timeIntervalSince1970)
            guard time >= state.observedAt else { return (nil, false) }
            try state.prune(now: time)
            let value = state.attempts.first { $0.screen == screen }
            if let value, time < (try deviceTimestamp(value.acceptedAt)) { return (nil, false) }
            return (value, true)
        }
    }

    private func matches(_ state: DeviceState, _ expected: SessionRecord) throws -> Bool {
        guard expected.deviceGeneration == nil || expected.deviceGeneration == state.generation else { return false }
        guard expected.deviceRefreshRequestID == nil || expected.deviceRefreshRequestID == state.refreshRequestID else { return false }
        return try state.session?.restore(generation: state.generation).credential == expected.credential
    }

    private func transaction<Value>(_ action: (inout DeviceState) throws -> (Value, Bool)) throws -> Value {
        try context.check()
        if case .some(.disabled) = persist {
            var state = memory
            let (value, changed) = try action(&state)
            if changed { _ = try state.encoded(); memory = state }
            return value
        }
        if case .some(.dir(let path)) = persist { _ = try DeviceFiles(path: path, baseDirectory: true) }
        let files = try DeviceFiles(path: location())
        let locking = usesKeychain ? try DeviceFiles(path: appLocation()) : files
        return try locking.locked {
            var installation: String?
            #if canImport(Security)
            if usesKeychain { installation = try establishInstallation(locking).id }
            #endif
            let identity: DeviceIdentity
            if let bytes = try files.read("identity", limit: 1024) {
                guard let decoded = try? JSONDecoder().decode(DeviceIdentity.self, from: bytes),
                      UUID(uuidString: decoded.installation) != nil else { throw deviceError("device_storage_corrupt") }
                if let installation, decoded.installation != installation {
                    guard decoded.backend == "keychain" else { throw deviceError("device_storage_corrupt") }
                    identity = DeviceIdentity(installation: installation, backend: "keychain")
                    try prepareNewIdentity(identity, files: files)
                } else { identity = decoded }
            } else {
                let backend = usesKeychain ? "keychain" : "file"
                guard try files.read("state") == nil else { throw deviceError("device_storage_corrupt") }
                identity = DeviceIdentity(installation: installation ?? UUID().uuidString, backend: backend)
                try prepareNewIdentity(identity, files: files)
            }
            guard boundInstallation == nil || boundInstallation == identity.installation else {
                throw ClientError(code: "session_changed", status: nil)
            }
            boundInstallation = identity.installation
            let bytes = try read(identity: identity, files: files)
            var state = try decode(bytes, identity: identity)
            try files.discardPendingWrites()
            let (value, changed) = try action(&state)
            if changed {
                try state.prune(now: Int64(Date().timeIntervalSince1970))
                try write(state.encoded(), identity: identity, files: files, creating: false)
            }
            return value
        }
    }

    private func prepareNewIdentity(_ identity: DeviceIdentity, files: DeviceFiles) throws {
        let empty = try DeviceState(scope: scope, installation: identity.installation).encoded()
        #if canImport(Security)
        if usesKeychain, let existing = try keychain(identity).loadIfPresent() {
            _ = try decode(existing, identity: identity)
        } else { try write(empty, identity: identity, files: files, creating: true) }
        #else
        try write(empty, identity: identity, files: files, creating: true)
        #endif
        try files.write("identity", data: JSONEncoder().encode(identity))
    }

    private func decode(_ bytes: Data, identity: DeviceIdentity) throws -> DeviceState {
        struct Version: Decodable { let version: Int }
        guard let header = try? JSONDecoder().decode(Version.self, from: bytes) else {
            throw deviceError("device_storage_corrupt")
        }
        guard header.version == 1 else { throw deviceError("device_storage_version_unsupported") }
        do {
            let state = try JSONDecoder().decode(DeviceState.self, from: bytes)
            guard state.scope == scope, state.installation == identity.installation,
                  state.session?.origin == nil || state.session?.origin == origin else {
                throw deviceError("device_storage_corrupt")
            }
            _ = try state.encoded()
            return state
        } catch let error as ClientError where DeviceLimits.errorCodes.contains(error.reason) { throw error }
        catch { throw deviceError("device_storage_corrupt") }
    }

    private func read(identity: DeviceIdentity, files: DeviceFiles) throws -> Data {
        guard identity.backend == (usesKeychain ? "keychain" : "file") else {
            throw deviceError("device_storage_corrupt")
        }
        #if canImport(Security)
        if usesKeychain { return try keychain(identity).load() }
        #endif
        guard identity.backend == "file", let data = try files.read("state") else {
            throw deviceError("device_storage_corrupt")
        }
        return data
    }

    private func write(_ data: Data, identity: DeviceIdentity, files: DeviceFiles, creating: Bool) throws {
        #if canImport(Security)
        if usesKeychain {
            if creating { try keychain(identity).create(data) }
            else { try keychain(identity).replace(data) }
            return
        }
        #endif
        try files.write("state", data: data)
    }

    #if canImport(Security)
    private func keychain(_ identity: DeviceIdentity) -> DeviceKeychain {
        DeviceKeychain(service: "com.chickinfry.device." + scope.app,
                        account: [identity.installation, scope.project, scope.environment, origin].joined(separator: "/"),
                        calls: keychainCalls)
    }
    #endif

    private nonisolated func appLocation() throws -> String {
        let root = try deviceStateRoot(persist)
        let base = URL(fileURLWithPath: root, isDirectory: true).standardizedFileURL
        guard root.hasPrefix("/"), !["/tmp", "/private/tmp", "/var/tmp"].contains(base.path) else { throw deviceError() }
        if case .some(.dir) = persist { return [root, scope.app].joined(separator: "/") }
        var ancestor = base
        while ancestor.path != "/" {
            guard !FileManager.default.fileExists(atPath: ancestor.appendingPathComponent(".git").path) else {
                throw deviceError()
            }
            ancestor.deleteLastPathComponent()
        }
        return [root, scope.app].joined(separator: "/")
    }

    private nonisolated func location() throws -> String {
        let encodedOrigin = Data(origin.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "=", with: "")
        return ([try appLocation(), scope.project, scope.environment] + stride(from: 0, to: encodedOrigin.count, by: 128).map {
            String(Array(encodedOrigin)[$0..<min($0 + 128, encodedOrigin.count)])
        }).joined(separator: "/")
    }

    public nonisolated var description: String { "DeviceSessionStore" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror { Mirror(self, children: EmptyCollection<Mirror.Child>()) }
}

private func deviceTimestamp(_ value: String) throws -> Int64 {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    var date = formatter.date(from: value)
    if date == nil { formatter.formatOptions = [.withInternetDateTime]; date = formatter.date(from: value) }
    guard let date, date.timeIntervalSince1970 >= 0,
          date.timeIntervalSince1970 < Double(Int64.max - DeviceLimits.attemptLifetime) else {
        throw deviceError("device_storage_corrupt")
    }
    return Int64(date.timeIntervalSince1970)
}
