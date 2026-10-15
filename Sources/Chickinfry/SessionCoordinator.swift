import Foundation

/// Coordinates refresh for one storage unit, including credentials with an unknown consumption result.
public actor SessionCoordinator: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private struct Flight {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<SessionRecord?, any Error>]
    }
    private var flights: [SessionCredential: Flight] = [:]
    private var uncertain: Set<SessionCredential> = []

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
                    return
                }
                let id = UUID()
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
                            do { refreshed = try await perform() }
                            catch let rejection as ServerRejection where rejection.error.status == 401 {
                                unknown = true
                                _ = try await sessionStoreCall { try await store.clear(ifMatching: expected) }
                                unknown = false
                                throw rejection.error
                            } catch {
                                unknown = true
                                throw error
                            }
                            unknown = true
                            _ = try await sessionStoreCall { try await store.replace(refreshed, ifMatching: expected) }
                            result = .success(try await loadSession(store, origin: expected.origin))
                            unknown = false
                        }
                    } catch { result = .failure(error) }
                    self.complete(key: key, id: id, result: result, unknown: unknown)
                }
                flights[key] = Flight(id: id, task: task, waiters: [waiter: continuation])
            }
        } onCancel: {
            Task { await self.cancel(key: key, waiter: waiter) }
        }
    }

    private func complete(key: SessionCredential, id: UUID, result: Result<SessionRecord?, any Error>, unknown: Bool) {
        guard let flight = flights[key], flight.id == id else { return }
        if unknown { uncertain.insert(key) }
        flights[key] = nil
        for continuation in flight.waiters.values { continuation.resume(with: result) }
    }

    private func cancel(key: SessionCredential, waiter: UUID) {
        guard var flight = flights[key], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty {
            uncertain.insert(key)
            flights[key] = nil
            flight.task.cancel()
        } else { flights[key] = flight }
        continuation.resume(throwing: OperationError(code: "cancelled", status: nil))
    }

    public nonisolated var description: String { "SessionCoordinator" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>(), displayStyle: .class)
    }
}
