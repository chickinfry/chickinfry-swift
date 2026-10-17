import Foundation
@_spi(Conformance) import Chickinfry

final class SecretValues: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<String>
    init(_ values: Set<String>) { storage = values }
    var values: Set<String> { lock.withLock { storage } }
    func insert(_ value: String) { _ = lock.withLock { storage.insert(value) } }
    func removeAll() { lock.withLock { storage.removeAll() } }
}

actor ObservedStore: SessionStore {
    nonisolated let origin: String
    nonisolated let coordinator: SessionCoordinator
    let backing: MemorySessionStore
    nonisolated let trace = SessionTrace()

    init(origin: String) throws {
        let backing = try MemorySessionStore(origin: origin)
        self.backing = backing
        self.origin = backing.origin
        self.coordinator = backing.coordinator
    }

    func load() async throws -> SessionRecord? { try await backing.load() }
    func save(_ session: SessionRecord) async throws {
        try await backing.save(session)
    }
    func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool {
        let replaced = try await backing.replace(session, ifMatching: expected)
        return replaced
    }
    func clear(ifMatching expected: SessionRecord) async throws -> Bool {
        let removed = try await backing.clear(ifMatching: expected)
        return removed
    }
    func state() async -> (SessionRecord?, Int, [JSON]) {
        let snapshot = await backing.conformanceSnapshot()
        return (snapshot.record, snapshot.revision, trace.values)
    }
}

final class SessionTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts: [JSON] = []
    func record(_ value: JSON) { lock.withLock { attempts.append(value) } }
    var values: [JSON] { lock.withLock { attempts } }
}
