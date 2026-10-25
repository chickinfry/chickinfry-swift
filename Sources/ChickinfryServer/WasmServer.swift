#if os(WASI)
import CChickinfryExecutor
import FoundationEssentials

public enum WasmServer {
    // The JS boot latch owns idle → pending → ready/failed; each generation creates a new instance.
    nonisolated(unsafe) private static var application: Application?
    nonisolated(unsafe) private static var tasks: [Int32: Task<Void, Never>] = [:]
    private enum Event {
        case start(Int32, UInt64, UInt64?, @Sendable () async -> ServerResponse)
        case cancel(Int32)
        case result(Int32, Bool, Data)
        case observation(Int32, CommitTransmission, Bool)
    }
    nonisolated(unsafe) private static var events: [Event] = []
    nonisolated(unsafe) private static var draining = false
    nonisolated(unsafe) private static var cancelledCalls: Set<Int32> = []
    private static let runtime = HostRuntime(send: { call in
        guard let count = Int32(exactly: call.bytes.count) else {
            receive(call.id, succeeded: false, bytes: Data())
            return
        }
        call.bytes.withUnsafeBytes { chik_host_call(call.channel.rawValue, call.id, $0.baseAddress, count) }
    }, settle: { call, response in finish(call, response: response) })

    private static func finish(_ call: Int32, response: ServerResponse) {
        tasks.removeValue(forKey: call)
        response.body.withUnsafeBytes { chik_settle(call, Int32(response.status), $0.baseAddress, Int32($0.count)) }
    }

    private static func enqueue(_ event: Event) {
        events.append(event)
        guard !draining else { return }
        draining = true
        // Preserve synchronous JS event order without serializing the request tasks.
        Task {
            var index = 0
            while index < events.count {
                let event = events[index]
                index += 1
                switch event {
                case .start(let call, let rid, let deadline, let operation):
                    let cancelled = cancelledCalls.remove(call) != nil
                    do { try await runtime.start(call, rid: rid, deadlineNanoseconds: deadline, cancelled: cancelled) { await operation() } }
                    catch { finish(call, response: .failure("operation_failed", status: 500)) }
                case .cancel(let call):
                    cancelledCalls.remove(call)
                    await runtime.cancel(call)
                case .result(let call, let success, let bytes): await runtime.receive(call, succeeded: success, bytes: bytes)
                case .observation(let call, let transmission, let complete):
                    await runtime.observeCommit(call, transmission: transmission, responseComplete: complete)
                }
            }
            events.removeAll(keepingCapacity: true)
            draining = false
        }
    }

    public static func start(_ application: Application, setup: @escaping @Sendable () async throws -> ApplicationOptions) {
        installWasmExecutors()
        Task {
            do {
                _ = try await setup()
                self.application = application
                chik_settle(0, 200, nil, 0)
            } catch { chik_settle(0, 500, nil, 0) }
        }
    }

    public static func handle(_ call: Int32, metadata: UnsafePointer<UInt8>, metadataCount: Int32,
                              body: UnsafePointer<UInt8>, bodyCount: Int32) {
        struct Metadata: Decodable {
            let operation: String
            let context: RequestContext
            let rid: UInt64?
            let deadlineMilliseconds: UInt64?
        }
        guard call > 0, metadataCount >= 0, bodyCount >= 0, tasks[call] == nil, let application,
              let frame = try? JSONDecoder().decode(Metadata.self, from: Data(bytes: metadata, count: Int(metadataCount))),
              frame.deadlineMilliseconds.map({ $0 <= UInt64.max / 1_000_000 }) ?? true else {
            finish(call, response: .failure("operation_failed", status: 500))
            return
        }
        // Copy before suspension; every completion owns its response allocation until JS copies it.
        let input = Data(bytes: body, count: Int(bodyCount))
        if let rid = frame.rid {
            enqueue(.start(call, rid, frame.deadlineMilliseconds.map { $0 * 1_000_000 }, {
                await application.handle(frame.operation, body: input, context: frame.context)
            }))
        } else {
            tasks[call] = Task {
                let response = await application.handle(frame.operation, body: input, context: frame.context)
                finish(call, response: response)
            }
        }
    }

    static func cancel(_ invocation: Int32) {
        tasks[invocation]?.cancel()
        cancelledCalls.insert(invocation)
        enqueue(.cancel(invocation))
    }

    static func receive(_ call: Int32, succeeded: Bool, bytes: Data) {
        enqueue(.result(call, succeeded, bytes))
    }

    static func observeCommit(_ call: Int32, transmission: CommitTransmission, responseComplete: Bool) {
        enqueue(.observation(call, transmission, responseComplete))
    }
}

@_cdecl("chik_allocate")
public func chikAllocate(_ count: Int32) -> UnsafeMutablePointer<UInt8> {
    .allocate(capacity: max(1, Int(count)))
}

@_cdecl("chik_deallocate")
public func chikDeallocate(_ pointer: UnsafeMutablePointer<UInt8>) { pointer.deallocate() }

@_cdecl("chik_run_job")
public func chikRunJob(_ job: UInt) { WasmExecutor.run(job) }

@_cdecl("chik_host_result")
@_spi(Generated)
public func chikHostResult(_ call: Int32, _ succeeded: Int32, _ bytes: UnsafePointer<UInt8>, _ count: Int32) {
    guard count >= 0 else { WasmServer.receive(call, succeeded: false, bytes: Data()); return }
    let result = Data(bytes: bytes, count: Int(count))
    WasmServer.receive(call, succeeded: succeeded == 1, bytes: result)
}

@_cdecl("chik_cancel")
@_spi(Generated)
public func chikCancel(_ invocation: Int32) { WasmServer.cancel(invocation) }

@_cdecl("chik_commit_observed")
@_spi(Generated)
public func chikCommitObserved(_ call: Int32, _ transmission: Int32, _ responseComplete: Int32) {
    guard let transmission = CommitTransmission(rawValue: transmission), [0, 1].contains(responseComplete) else { return }
    WasmServer.observeCommit(call, transmission: transmission, responseComplete: responseComplete == 1)
}
#endif
