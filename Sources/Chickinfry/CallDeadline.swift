import Foundation

struct CallDeadline: Sendable {
    private let end: UInt64

    init(timeout: TimeInterval) {
        end = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    }

    func remaining() throws -> TimeInterval {
        guard !Task.isCancelled else { throw ClientError(code: "cancelled", status: nil) }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < end else { throw ClientError(code: "timeout", status: nil) }
        return Double(end - now) / 1_000_000_000
    }

    func wait<Value: Sendable>(_ operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        let timeout = try remaining()
        let waiter = DeadlineWait<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiter.start(timeout: timeout, continuation: continuation, operation: operation)
            }
        } onCancel: {
            waiter.finish(.failure(ClientError(code: "cancelled", status: nil)))
        }
    }
}

// The winner releases its continuation immediately, even if a custom store ignores cancellation.
private final class DeadlineWait<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var continuation: CheckedContinuation<Value, any Error>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    func start(timeout: TimeInterval, continuation: CheckedContinuation<Value, any Error>,
               operation: @escaping @Sendable () async throws -> Value) {
        let cancelled = lock.withLock {
            guard !finished else { return true }
            self.continuation = continuation
            #if CHICKINFRY_CONFORMANCE
            let observation = Conformance.call
            #endif
            work = Task.detached {
                #if CHICKINFRY_CONFORMANCE
                await Conformance.$call.withValue(observation) {
                    do { self.finish(.success(try await operation())) }
                    catch { self.finish(.failure(error)) }
                }
                #else
                do { self.finish(.success(try await operation())) }
                catch { self.finish(.failure(error)) }
                #endif
            }
            timer = Task.detached {
                do { try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
                catch { return }
                self.finish(.failure(ClientError(code: "timeout", status: nil)))
            }
            return false
        }
        if cancelled { continuation.resume(throwing: ClientError(code: "cancelled", status: nil)) }
    }

    func finish(_ result: Result<Value, any Error>) {
        let completion = lock.withLock { () -> (CheckedContinuation<Value, any Error>?, Task<Void, Never>?, Task<Void, Never>?)? in
            guard !finished else { return nil }
            finished = true
            let completion = (continuation, work, timer)
            continuation = nil
            work = nil
            timer = nil
            return completion
        }
        guard let (continuation, work, timer) = completion else { return }
        work?.cancel()
        timer?.cancel()
        continuation?.resume(with: result)
    }
}
