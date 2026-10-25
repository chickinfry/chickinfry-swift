#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

@_spi(Generated) public struct HostRequest: Sendable {
    @TaskLocal public static var current: HostRequest?
    private let runtime: HostRuntime
    private let invocation: Int32

    fileprivate init(runtime: HostRuntime, invocation: Int32) {
        self.runtime = runtime
        self.invocation = invocation
    }

    public func database(_ frame: Data) async throws -> Data {
        try await runtime.perform(invocation, channel: .database, bytes: frame)
    }

    public func environment(_ name: String) async throws -> Data {
        try await runtime.perform(invocation, channel: .environment, bytes: HostFrame.encode(["name": .string(name)]))
    }

    public func log(level: String, message: String) async throws {
        _ = try await runtime.perform(invocation, channel: .log,
                                      bytes: HostFrame.encode(["level": .string(level), "message": .string(message)]))
    }
}

struct HostCall: Sendable {
    let id: Int32
    let channel: HostChannel
    let bytes: Data
}

enum CommitTransmission: Int32, Sendable { case unobserved = 0, notStarted = 1, mayHaveStarted = 2 }
enum RequestPhase: Sendable, Equatable { case running, finishing, stopping }
enum TransactionPhase: Sendable, Equatable {
    case idle, beginning, active(UInt64), committing(UInt64), rollingBack(UInt64)
    case committed, rolledBack, commitUnknown, discarded
}

struct RequestSnapshot: Sendable, Equatable {
    var phase: RequestPhase = .running
    var transaction: TransactionPhase = .idle
    var outcomeUnknown: Bool? = false
    var cleanupComplete = false
}

actor HostRuntime {
    private struct Request {
        let rid: UInt64
        var state = RequestSnapshot()
        var task: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var response: ServerResponse?
        var finish: Int32?
        var cancellingFinish = false
    }
    private struct Pending {
        let invocation: Int32
        let operation: String
        let continuation: CheckedContinuation<Data, any Error>?
        var transmission: CommitTransmission = .unobserved
        var responseComplete = false
    }

    private let send: @Sendable (HostCall) -> Void
    private let settle: @Sendable (Int32, ServerResponse) -> Void
    private var requests: [Int32: Request] = [:]
    private var pending: [Int32: Pending] = [:]
    private var nextCall: Int32 = 1
    private var lastInvocation: Int32 = 0

    init(send: @escaping @Sendable (HostCall) -> Void, settle: @escaping @Sendable (Int32, ServerResponse) -> Void) {
        self.send = send
        self.settle = settle
    }

    func start(_ invocation: Int32, rid: UInt64, deadlineNanoseconds: UInt64? = nil, cancelled: Bool = false,
               operation: @escaping @Sendable () async throws -> ServerResponse) throws {
        guard invocation > lastInvocation, rid > 0, rid <= 9_007_199_254_740_991,
              !requests.values.contains(where: { $0.rid == rid }) else { throw HostFailure.invalidFrame }
        lastInvocation = invocation
        requests[invocation] = Request(rid: rid)
        let host = HostRequest(runtime: self, invocation: invocation)
        requests[invocation]?.task = Task {
            let response: ServerResponse
            do {
                try Task.checkCancellation()
                response = try await HostRequest.$current.withValue(host) { try await operation() }
            }
            catch { response = .failure("operation_failed", status: 500) }
            taskCompleted(invocation, response: response)
        }
        if let deadlineNanoseconds {
            requests[invocation]?.deadline = Task {
                do { try await Task.sleep(nanoseconds: deadlineNanoseconds) }
                catch { return }
                cancel(invocation)
            }
        }
        if cancelled || Task.isCancelled { cancel(invocation) }
    }

    func snapshot(_ invocation: Int32) -> RequestSnapshot? { requests[invocation]?.state }

    func perform(_ invocation: Int32, channel: HostChannel, bytes: Data) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try Task.checkCancellation()
                    guard let request = requests[invocation], request.state.phase == .running else { throw CancellationError() }
                    let (frame, operation) = try HostFrame.request(channel, bytes: bytes, rid: request.rid)
                    let call = try allocateCall()
                    if channel == .database { try transition(invocation, operation: operation, frame: bytes) }
                    pending[call] = Pending(invocation: invocation, operation: operation, continuation: continuation)
                    send(HostCall(id: call, channel: channel, bytes: frame))
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { await self.cancel(invocation) }
        }
    }

    private func transition(_ invocation: Int32, operation: String, frame: Data) throws {
        guard var request = requests[invocation] else { throw CancellationError() }
        let lease = try HostFrame.decode(frame)["lease"]?.handle
        switch operation {
        case "begin":
            guard [.idle, .committed, .rolledBack].contains(request.state.transaction) else { throw HostFailure.invalidFrame }
            request.state.transaction = .beginning
        case "exec", "commit", "rollback":
            guard let lease, request.state.transaction == .active(lease) else { throw HostFailure.invalidFrame }
            if operation == "commit" { request.state.transaction = .committing(lease) }
            if operation == "rollback" { request.state.transaction = .rollingBack(lease) }
        default: break
        }
        requests[invocation] = request
    }

    func observeCommit(_ call: Int32, transmission: CommitTransmission, responseComplete: Bool) {
        guard var value = pending[call], value.operation == "commit" else { return }
        // Evidence can advance to transmission/response, never erase an earlier observation.
        if transmission != .unobserved, value.transmission != .mayHaveStarted { value.transmission = transmission }
        value.responseComplete = value.responseComplete || responseComplete
        pending[call] = value
    }

    func receive(_ call: Int32, succeeded: Bool, bytes: Data) {
        guard let value = pending.removeValue(forKey: call), var request = requests[value.invocation] else { return }
        if value.operation == "finish" {
            guard request.finish == call else { return }
            if succeeded, (try? HostFrame.response("finish", bytes: bytes)) == [:] {
                request.state.cleanupComplete = true
                requests[value.invocation] = request
                settleIfComplete(value.invocation)
            } else {
                request.state.phase = .stopping
                requests[value.invocation] = request
            }
            return
        }
        do {
            guard succeeded else { throw HostFailure.transport }
            let frame = try HostFrame.response(value.operation, bytes: bytes)
            let code: String?
            if case .string(let error) = frame["error"] { code = error } else { code = nil }
            switch value.operation {
            case "begin": request.state.transaction = code == nil ? .active(frame["lease"]!.handle!) : .discarded
            case "commit":
                request.state.transaction = code == "commit_unknown" ? .commitUnknown : code == nil ? .committed : .discarded
                request.state.outcomeUnknown = code == "commit_unknown"
            case "rollback": request.state.transaction = code == nil ? .rolledBack : .discarded
            default: break
            }
            requests[value.invocation] = request
            if let code { value.continuation?.resume(throwing: HostFailure(code: code)) }
            else { value.continuation?.resume(returning: bytes) }
        } catch {
            classifyInterruptedCommit(value, state: &request.state)
            if value.operation == "begin" || value.operation == "rollback" { request.state.transaction = .discarded }
            requests[value.invocation] = request
            value.continuation?.resume(throwing: error)
            cancel(value.invocation)
        }
    }

    func cancel(_ invocation: Int32) {
        guard var request = requests[invocation] else { return }
        request.state.phase = .stopping
        request.deadline?.cancel()
        let interrupted = pending.filter { $0.value.invocation == invocation && $0.value.operation != "finish" }
        for (call, value) in interrupted {
            pending.removeValue(forKey: call)
            classifyInterruptedCommit(value, state: &request.state)
            value.continuation?.resume(throwing: CancellationError())
        }
        switch request.state.transaction {
        case .beginning, .active, .rollingBack: request.state.transaction = .discarded
        default: break
        }
        request.task?.cancel()
        requests[invocation] = request
        beginFinish(invocation, cancel: true)
    }

    private func classifyInterruptedCommit(_ value: Pending, state: inout RequestSnapshot) {
        guard value.operation == "commit" else { return }
        if value.responseComplete || value.transmission == .notStarted {
            state.outcomeUnknown = false
            state.transaction = .discarded
        } else if value.transmission == .mayHaveStarted {
            state.outcomeUnknown = true
            state.transaction = .commitUnknown
        } else {
            state.outcomeUnknown = nil
            state.transaction = .discarded
        }
    }

    private func taskCompleted(_ invocation: Int32, response: ServerResponse) {
        guard var request = requests[invocation] else { return }
        let hasPendingCalls = pending.values.contains(where: { $0.invocation == invocation })
        request.response = request.state.phase == .stopping || hasPendingCalls ? .failure("operation_failed", status: 500) : response
        request.task = nil
        request.deadline?.cancel()
        requests[invocation] = request
        if request.state.phase == .running {
            if hasPendingCalls {
                cancel(invocation)
            } else {
                requests[invocation]?.state.phase = .finishing
                if case .active = request.state.transaction { requests[invocation]?.state.transaction = .discarded }
                beginFinish(invocation, cancel: false)
            }
        }
        settleIfComplete(invocation)
    }

    private func beginFinish(_ invocation: Int32, cancel: Bool) {
        guard var request = requests[invocation], !request.state.cleanupComplete,
              request.finish == nil || (cancel && !request.cancellingFinish) else { return }
        if let old = request.finish { pending.removeValue(forKey: old) }
        guard let call = try? allocateCall(), let frame = try? HostFrame.encode([
            "rid": .integer(Int64(request.rid)), "cancel": .bool(cancel)
        ]) else { return }
        request.finish = call
        request.cancellingFinish = cancel
        requests[invocation] = request
        pending[call] = Pending(invocation: invocation, operation: "finish", continuation: nil)
        send(HostCall(id: call, channel: .finish, bytes: frame))
    }

    private func settleIfComplete(_ invocation: Int32) {
        guard let request = requests[invocation], request.state.cleanupComplete, let response = request.response else { return }
        requests.removeValue(forKey: invocation)
        settle(invocation, response)
    }

    private func allocateCall() throws -> Int32 {
        guard nextCall < Int32.max else { throw HostFailure.invalidFrame }
        defer { nextCall += 1 }
        return nextCall
    }
}
