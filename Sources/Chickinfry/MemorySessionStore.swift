import Foundation

/// In-process session storage. Persistence and cross-process coordination belong to the app.
public actor MemorySessionStore: SessionStore, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// The one origin this store holds records for.
    public nonisolated let origin: String
    /// The single coordinator shared by every access to this store.
    public nonisolated let coordinator = SessionCoordinator()
    private var session: SessionRecord?
    #if CHICKINFRY_CONFORMANCE
    private var conformanceRevision = 0

    @_spi(Conformance) public func conformanceSnapshot() -> (record: SessionRecord?, revision: Int) {
        (session, conformanceRevision)
    }
    #endif

    /// Creates empty in-process storage, or throws if the origin is invalid.
    public init(origin: String) throws {
        self.origin = try ClientTransport.validateOrigin(origin)
    }

    /// Returns the stored record, or nil when none is present.
    public func load() async throws -> SessionRecord? { session }

    /// Makes the record available before returning; an origin mismatch throws.
    public func save(_ session: SessionRecord) async throws {
        guard session.origin == origin else { throw OperationError(code: "invalid_origin", status: nil) }
        self.session = session
        #if CHICKINFRY_CONFORMANCE
        conformanceRevision += 1
        #endif
    }

    /// Returns true after replacement or false on a credential mismatch or absence; an origin mismatch throws.
    public func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool {
        guard session.origin == origin else { throw OperationError(code: "invalid_origin", status: nil) }
        guard self.session?.credential == expected.credential else { return false }
        self.session = session
        #if CHICKINFRY_CONFORMANCE
        conformanceRevision += 1
        #endif
        return true
    }

    /// Returns true after removal, or false on a credential mismatch or absence.
    public func clear(ifMatching expected: SessionRecord) async throws -> Bool {
        guard session?.credential == expected.credential else { return false }
        session = nil
        #if CHICKINFRY_CONFORMANCE
        conformanceRevision += 1
        #endif
        return true
    }

    public nonisolated var description: String { "MemorySessionStore" }
    public nonisolated var debugDescription: String { description }
    public nonisolated var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>(), displayStyle: .class)
    }
}
