#if CHICKINFRY_CONFORMANCE
import Foundation

@_spi(Conformance) public enum Conformance {
    @TaskLocal public static var call: Call?
    @TaskLocal public static var construction: Construction?
    @TaskLocal static var refreshTransmission: Transmission?

    final class Transmission: @unchecked Sendable {
        private let lock = NSLock()
        private var result: Bool?
        private var continuation: CheckedContinuation<Bool, Never>?

        func finish(_ sent: Bool = false) {
            let pending = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard result == nil else { return nil }
                result = sent
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(returning: sent)
        }

        func wait() async -> Bool {
            await withTaskCancellationHandler {
                await withCheckedContinuation { pending in
                    let completed = lock.withLock { () -> Bool? in
                        if let result { return result }
                        continuation = pending
                        return nil
                    }
                    if let completed { pending.resume(returning: completed) }
                }
            } onCancel: { self.finish() }
        }
    }

    public final class Construction: @unchecked Sendable {
        private let lock = NSLock()
        private var requests = 0
        public init() {}
        public var count: Int { lock.withLock { requests } }
        func networkEntry() { lock.withLock { requests += 1 } }
    }

    public struct Event: Sendable {
        public let phase: String
        public let httpStatus: Int?
        public let readBytes: Int
        public let retainedBytes: Int
        public let peakRetainedBytes: Int
    }

    /// Read-only access to the actual allocations, independent of the accounting counters.
    public final class Buffers: @unchecked Sendable {
        public let exchange: UUID
        public let holdOwner: @Sendable () -> (@Sendable () -> Void)?
        private let response: @Sendable () -> Int
        private let accumulated: @Sendable () -> Int
        public var responseBytes: Int { response() }
        public var accumulatedBytes: Int { accumulated() }
        init(exchange: UUID, response: @escaping @Sendable () -> Int, accumulated: @escaping @Sendable () -> Int,
             holdOwner: @escaping @Sendable () -> (@Sendable () -> Void)?) {
            self.exchange = exchange
            self.holdOwner = holdOwner
            self.response = response
            self.accumulated = accumulated
        }
    }

    public final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var read = 0
        private var retained = 0
        private var peak = 0
        private var status: Int?
        private var pending: [(String, Int?)] = []
        private var lifecycle: [(String, Int?)] = []
        private var followers: [Call] = []
        private var publications: [(value: Event, emit: Bool, followers: [Call])] = []
        private var publishing = false
        private var selected = false
        private var sent = false
        private var confirmed = false
        private var uncertainRefresh = false
        public let event: @Sendable (Event) -> Void
        public let barrier: @Sendable (String, String?) async throws -> Void
        public let clear: @Sendable (SessionRecord, Bool) -> Void
        public let buffers: @Sendable (Buffers, Event) -> Void
        public let credentials: @Sendable (SessionRecord) -> Void

        public init(event: @escaping @Sendable (Event) -> Void,
                    barrier: @escaping @Sendable (String, String?) async throws -> Void,
                    clear: @escaping @Sendable (SessionRecord, Bool) -> Void,
                    buffers: @escaping @Sendable (Buffers, Event) -> Void = { _, _ in },
                    credentials: @escaping @Sendable (SessionRecord) -> Void = { _ in }) {
            self.event = event
            self.barrier = barrier
            self.clear = clear
            self.buffers = buffers
            self.credentials = credentials
        }

        public var retainedBytes: Int { lock.withLock { retained } }

        public var outcomeUnknown: Bool {
            lock.withLock { uncertainRefresh || (sent && !confirmed) }
        }

        func exchange(immediate: Bool) {
            lock.withLock {
                pending = []; lifecycle = []; followers = []
                selected = immediate; status = nil; sent = false; confirmed = false
            }
        }

        func transmitted() { lock.withLock { sent = true } }
        func confirmedOutcome() { lock.withLock { confirmed = true } }
        func refreshUnknown() { lock.withLock { uncertainRefresh = true } }

        func account(_ delta: Int) {
            lock.withLock {
                retained += delta
                peak = max(peak, retained)
            }
        }

        func observe(_ phase: String, status: Int? = nil, bytes: Int = 0, immediate: Bool = false) {
            lock.withLock {
                if let status { self.status = status }
                read += bytes
                let shared = phase == "headers" || phase == "cancel-requested"
                    || phase == "cancel-observed" || phase == "reader-closed"
                if shared { lifecycle.append((phase, self.status)) }
                let emit = phase == "read" || phase == "limit" || immediate || selected
                if !emit { pending.append((phase, self.status)) }
                publications.append((snapshot(phase, status: self.status), emit, shared ? followers : []))
            }
            publish()
        }

        func project(to follower: Call) {
            guard self !== follower else { return }
            lock.withLock {
                // Keep each waiter's own byte history and receive late reader termination.
                follower.lock.withLock {
                    follower.pending = lifecycle
                    follower.status = status
                }
                followers.append(follower)
            }
        }

        func select() {
            lock.withLock {
                selected = true
                publications += pending.map { (snapshot($0.0, status: $0.1), true, []) }
                pending = []
            }
            publish()
        }

        private func publish() {
            let started = lock.withLock {
                guard !publishing else { return false }
                publishing = true
                return true
            }
            guard started else { return }
            while true {
                let values = lock.withLock {
                    let values = publications
                    publications = []
                    if values.isEmpty { publishing = false }
                    return values
                }
                guard !values.isEmpty else { return }
                // One drainer preserves replay and follower order without calling out under the lock.
                for (value, emit, recipients) in values {
                    if emit { event(value) }
                    for follower in recipients { follower.observe(value.phase, status: value.httpStatus) }
                }
            }
        }

        func inspect(_ buffers: Buffers) {
            let value = lock.withLock { snapshot("read", status: status) }
            self.buffers(buffers, value)
        }

        private func snapshot(_ phase: String, status: Int?) -> Event {
            Event(phase: phase, httpStatus: status, readBytes: read,
                  retainedBytes: retained, peakRetainedBytes: peak)
        }
    }
}
#endif
