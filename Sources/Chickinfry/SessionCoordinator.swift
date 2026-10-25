import Foundation

enum SessionCommit: Sendable {
    case persisted
    case stale
    case memory(UInt64, local: UInt64)
}

/// Coordinates refresh for one storage unit, including credentials with an unknown consumption result.
public actor SessionCoordinator: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<SessionRecord?, any Error>]
        #if CHICKINFRY_CONFORMANCE
        var transportObservation: Conformance.Call?
        var observations: [UUID: Conformance.Call] = [:]
        var result: Result<SessionRecord?, any Error>?
        #endif
    }
    private var flights: [SessionCredential: Flight] = [:]
    private var uncertain: Set<SessionCredential> = []
    private var volatileSession: SessionRecord?
    private var volatileAuthGeneration: UInt64?
    private var volatileLocalAuthGeneration: UInt64?
    private var usesVolatileSession = false
    private var mutationEpoch: UInt64 = 0

    func authenticationSnapshot(_ snapshot: DeviceSnapshot) -> DeviceSnapshot {
        var value = snapshot
        if usesVolatileSession {
            value.session = volatileSession
            value.userID = volatileSession?.userID
            value.sessionID = volatileSession?.sessionID
            value.authGeneration = max(value.authGeneration, volatileAuthGeneration ?? 0)
        }
        return value
    }

    func authenticationGenerationFloor() -> UInt64 { volatileAuthGeneration ?? 0 }

    func targetAuthenticationGeneration(_ snapshot: DeviceSnapshot, session: SessionRecord,
                                         consuming: DeviceAttempt?) throws -> UInt64 {
        let switches = snapshot.sessionID != session.sessionID
        guard !switches || snapshot.authGeneration < UInt64.max else { throw deviceError("device_storage_full") }
        return switches ? snapshot.authGeneration + 1 : snapshot.authGeneration
    }

    func commitAuthentication(_ session: SessionRecord, store: any DeviceAuthenticationStore,
                               before: DeviceSnapshot, consuming: DeviceAttempt?, confirmedEmail: String?) async throws -> SessionCommit {
        var latest = before
        for _ in 0..<DeviceLimits.commitAttempts {
            guard confirmationIsCurrent(latest, before: before, consuming: consuming) else {
                try await discardConsumedAttempt(consuming, store: store)
                return .stale
            }
            let generation = try targetAuthenticationGeneration(latest, session: session, consuming: consuming)
            if try await store.install(session, consumingEmail: consuming?.email ?? confirmedEmail, ifGeneration: latest.generation,
                                       authGeneration: generation) { return .persisted }
            latest = try await store.snapshot()
        }
        guard confirmationIsCurrent(latest, before: before, consuming: consuming) else {
            try await discardConsumedAttempt(consuming, store: store)
            return .stale
        }
        return .memory(try targetAuthenticationGeneration(latest, session: session, consuming: consuming),
                       local: latest.localAuthGeneration)
    }

    private func discardConsumedAttempt(_ attempt: DeviceAttempt?, store: any DeviceAuthenticationStore) async throws {
        guard let attempt else { return }
        do {
            for _ in 0..<DeviceLimits.commitAttempts {
                let snapshot = try await store.snapshot()
                guard snapshot.attempts.contains(where: { $0.id == attempt.id && $0.screen == attempt.screen }) else { return }
                if try await store.discardAttempt(attempt, ifGeneration: snapshot.generation) { return }
            }
        } catch {
            var failure = (error as? OperationError) ?? deviceError()
            failure.devicePreparation = true
            throw failure
        }
    }

    private func confirmationIsCurrent(_ latest: DeviceSnapshot, before: DeviceSnapshot,
                                       consuming: DeviceAttempt?) -> Bool {
        guard latest.authGeneration == before.authGeneration else { return false }
        guard let consuming else { return true }
        return latest.attempts.contains { $0.id == consuming.id && $0.screen == consuming.screen && $0.email == consuming.email }
    }

    func current(store: any SessionStore) async throws -> SessionRecord? {
        if let device = store as? DeviceSessionStore { try await device.prepareInstallation() }
        if usesVolatileSession {
            if let device = store as? any DeviceAuthenticationStore {
                do {
                    let snapshot = try await device.snapshot()
                    if let generation = volatileLocalAuthGeneration, snapshot.localAuthGeneration > generation {
                        discardVolatileSession()
                        return nil
                    }
                } catch let error as OperationError where error.code == "device_storage_unavailable" {
                    // E1 remains usable when storage cannot report a newer authentication boundary.
                }
            }
            return volatileSession
        }
        return try await sessionStoreCall { try await store.load() }
    }

    func discardVolatileSession() {
        volatileSession = nil
        volatileAuthGeneration = nil
        volatileLocalAuthGeneration = nil
        usesVolatileSession = false
        mutationEpoch &+= 1
    }

    func acceptAuthenticated(_ session: SessionRecord, store: any SessionStore,
                             expected: SessionRecord? = nil,
                             authGeneration: UInt64? = nil, localAuthGeneration: UInt64? = nil, lateIsEmpty: Bool = false,
                             persist: @Sendable () async throws -> SessionCommit) async throws -> SessionRecord? {
        if let expected, usesVolatileSession {
            guard try await current(store: store)?.credential == expected.credential else { return nil }
            volatileSession = session
            mutationEpoch &+= 1
            return session
        }
        var epoch = mutationEpoch
        var memoryGeneration = authGeneration ?? expected?.deviceAuthGeneration ?? 0
        var memoryLocalGeneration = localAuthGeneration ?? expected?.deviceAuthGeneration ?? 0
        do {
            switch try await sessionStoreCall(persist) {
            case .stale:
                return lateIsEmpty ? nil : try await current(store: store)
            case .persisted:
                memoryLocalGeneration = memoryGeneration
                if mutationEpoch == epoch { discardVolatileSession() }
                epoch = mutationEpoch
                return try await current(store: store)
            case .memory(let generation, let local):
                memoryGeneration = generation
                memoryLocalGeneration = local
            }
        } catch let error as OperationError
            where !error.devicePreparation && (error.code == "device_storage_unavailable" || error.code == "device_storage_full") {
            _ = error
        } catch {
            discardVolatileSession()
            throw error
        }
        guard mutationEpoch == epoch else { return lateIsEmpty ? nil : try await current(store: store) }
        volatileSession = session
        volatileAuthGeneration = memoryGeneration
        volatileLocalAuthGeneration = memoryLocalGeneration
        usesVolatileSession = true
        mutationEpoch &+= 1
        return session
    }

    private func clearAuthenticated(_ expected: SessionRecord, store: any SessionStore) async throws -> Bool {
        if usesVolatileSession {
            guard volatileSession?.credential == expected.credential else { return false }
            volatileSession = nil
            mutationEpoch &+= 1
            return true
        }
        return try await sessionStoreCall { try await store.clear(ifMatching: expected) }
    }
    #if CHICKINFRY_CONFORMANCE
    private var conformanceWork: [UUID: Task<Void, Never>] = [:]
    private var conformanceHooks: [UUID: Task<Void, any Error>] = [:]
    var conformanceTaskCount: Int { conformanceWork.count + conformanceHooks.count }
    var conformanceCompletingCount: Int { flights.values.filter { $0.result != nil }.count }

    @_spi(Conformance) public func conformanceShutdown() async {
        let work = Array(conformanceWork.values)
        let hooks = Array(conformanceHooks.values)
        for task in work { task.cancel() }
        for task in hooks { task.cancel() }
        for (key, flight) in flights {
            uncertain.insert(key)
            for waiter in flight.waiters.values {
                waiter.resume(throwing: OperationError(code: "cancelled", status: nil))
            }
        }
        flights = [:]
        for task in hooks { _ = await task.result }
        for task in work { await task.value }
        conformanceHooks = [:]
    }
    #endif

    /// Creates the coordinator shared by every wrapper of one physical session record.
    public init() {}

    var waitingCount: Int { flights.values.reduce(0) { $0 + $1.waiters.count } }

    private func commitRefresh(_ session: SessionRecord, expected: SessionRecord,
                               store: any SessionStore) async throws -> SessionCommit {
        guard let device = store as? any DeviceRefreshing else {
            return try await store.replace(session, ifMatching: expected) ? .persisted : .stale
        }
        for _ in 0..<DeviceLimits.commitAttempts {
            guard let current = try await device.refreshCandidate(ifMatching: expected) else { return .stale }
            if try await store.replace(session, ifMatching: current) { return .persisted }
        }
        guard let current = try await device.refreshCandidate(ifMatching: expected),
              let generation = current.deviceAuthGeneration else { return .stale }
        return .memory(generation, local: generation)
    }

    func refresh(expected: SessionRecord, store: any SessionStore,
                 perform: @escaping @Sendable () async throws -> SessionRecord) async throws -> SessionRecord? {
        let key = expected.credential
        let waiter = UUID()
        guard !Task.isCancelled else { throw OperationError(code: "cancelled", status: nil) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if flights[key] != nil {
                    flights[key]!.waiters[waiter] = continuation
                    #if CHICKINFRY_CONFORMANCE
                    let observation = Conformance.call
                    flights[key]!.observations[waiter] = observation
                    conformanceJoin(waiter: waiter, id: flights[key]!.id, observation: observation)
                    if let result = flights[key]!.result {
                        conformanceComplete(key: key, id: flights[key]!.id, waiter: waiter, result: result)
                    }
                    #endif
                    return
                }
                let id = UUID()
                #if CHICKINFRY_CONFORMANCE
                let transmission = Conformance.Transmission()
                #endif
                let task = Task {
                    var unknown = false
                    let result: Result<SessionRecord?, any Error>
                    do {
                        // Recheck after selection: storage I/O must not split flight publication.
                        let current = try await loadSession(store, origin: expected.origin)
                        if current?.credential != key {
                            result = .success(current)
                        } else {
                            guard !self.uncertain.contains(key) else {
                                throw OperationError(code: "invalid_token", status: 401)
                            }
                            if !self.usesVolatileSession, let device = store as? any DeviceRefreshing {
                                let claimed = try await sessionStoreCall { try await device.beginRefresh(ifMatching: expected) }
                                guard claimed else { throw OperationError(code: "invalid_token", status: 401) }
                            }
                            let refreshed: SessionRecord
                            do {
                                #if CHICKINFRY_CONFORMANCE
                                refreshed = try await Conformance.$refreshTransmission.withValue(transmission) {
                                    try await perform()
                                }
                                #else
                                refreshed = try await perform()
                                #endif
                            }
                            catch let rejection as ServerRejection where rejection.error.status == 401 {
                                unknown = true
                                let removed = try await self.clearAuthenticated(expected, store: store)
                                #if CHICKINFRY_CONFORMANCE
                                Conformance.call?.clear(expected, removed)
                                #endif
                                _ = removed
                                unknown = false
                                throw rejection.error
                            } catch {
                                unknown = true
                                #if CHICKINFRY_CONFORMANCE
                                Conformance.call?.refreshUnknown()
                                #endif
                                throw error
                            }
                            unknown = true
                            result = .success(try await self.acceptAuthenticated(refreshed, store: store, expected: expected) {
                                try await self.commitRefresh(refreshed, expected: expected, store: store)
                            })
                            unknown = false
                        }
                    } catch { result = .failure(error) }
                    #if CHICKINFRY_CONFORMANCE
                    transmission.finish()
                    #endif
                    await self.complete(key: key, id: id, result: result, unknown: unknown)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
                #if CHICKINFRY_CONFORMANCE
                conformanceWork[id] = task
                let observation = Conformance.call
                flights[key]!.transportObservation = observation
                flights[key]!.observations[waiter] = observation
                conformanceJoin(waiter: waiter, id: id, observation: observation, transmission: transmission)
                #endif
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    #if CHICKINFRY_CONFORMANCE
    private func conformanceJoin(waiter: UUID, id: UUID, observation: Conformance.Call?,
                                 transmission: Conformance.Transmission? = nil) {
        guard let observation else { return }
        conformanceHooks[waiter] = Task {
            if let transmission, !(await transmission.wait()) {
                try Task.checkCancellation()
                return
            }
            try Task.checkCancellation()
            try await observation.barrier("refresh-joined", id.uuidString)
        }
    }

    private func conformanceComplete(key: SessionCredential, id: UUID, waiter: UUID,
                                     result: Result<SessionRecord?, any Error>) {
        conformanceWork[waiter] = Task {
            defer { conformanceWork[waiter] = nil }
            let hookResult = await conformanceHooks[waiter]?.result
            conformanceHooks[waiter] = nil
            guard flights[key]?.id == id,
                  let continuation = flights[key]?.waiters.removeValue(forKey: waiter) else { return }
            let observation = flights[key]?.observations.removeValue(forKey: waiter)
            let transportObservation = flights[key]?.transportObservation
            if flights[key]?.waiters.isEmpty == true { flights[key] = nil }
            if case .failure(let error)? = hookResult { continuation.resume(throwing: error) }
            else {
                if case .failure = result, let observation { transportObservation?.project(to: observation) }
                continuation.resume(with: result)
            }
        }
    }
    #endif

    private func complete(key: SessionCredential, id: UUID, result: Result<SessionRecord?, any Error>, unknown: Bool) async {
        #if CHICKINFRY_CONFORMANCE
        defer { conformanceWork[id] = nil }
        #endif
        guard let flight = flights[key], flight.id == id else { return }
        if unknown {
            uncertain.insert(key)
            #if CHICKINFRY_CONFORMANCE
            for observation in flight.observations.values { observation.refreshUnknown() }
            #endif
        }
        #if CHICKINFRY_CONFORMANCE
        flights[key]?.result = result
        for waiter in flight.waiters.keys {
            conformanceComplete(key: key, id: id, waiter: waiter, result: result)
        }
        #else
        flights[key] = nil
        for continuation in flight.waiters.values { continuation.resume(with: result) }
        #endif
    }

    private func cancel(key: SessionCredential, waiter: UUID) async {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        #if CHICKINFRY_CONFORMANCE
        flight.observations.removeValue(forKey: waiter)?.refreshUnknown()
        conformanceHooks[waiter]?.cancel()
        #endif
        if flight.waiters.isEmpty {
            uncertain.insert(key)
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
        #if CHICKINFRY_CONFORMANCE
        _ = await conformanceHooks[waiter]?.result
        conformanceHooks[waiter] = nil
        #endif
        continuation.resume(throwing: OperationError(code: "cancelled", status: nil))
    }

    public nonisolated var description: String { "SessionCoordinator" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>(), displayStyle: .class)
    }
}
