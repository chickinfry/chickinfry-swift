import Foundation

/// Coordinates refresh for one storage unit, including credentials with an unknown consumption result.
public actor SessionCoordinator: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<SessionRecord?, any Error>]
        #if CHICKINFRY_CONFORMANCE
        var observations: [UUID: Conformance.Call] = [:]
        var result: Result<SessionRecord?, any Error>?
        #endif
    }
    private var flights: [SessionCredential: Flight] = [:]
    private var uncertain: Set<SessionCredential> = []
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
                                let removed = try await sessionStoreCall { try await store.clear(ifMatching: expected) }
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
                            _ = try await sessionStoreCall { try await store.replace(refreshed, ifMatching: expected) }
                            result = .success(try await loadSession(store, origin: expected.origin))
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
            flights[key]?.observations[waiter] = nil
            if flights[key]?.waiters.isEmpty == true { flights[key] = nil }
            if case .failure(let error)? = hookResult { continuation.resume(throwing: error) }
            else { continuation.resume(with: result) }
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
