#if os(WASI)
import CChickinfryExecutor
import FoundationEssentials

public enum WasmServer {
    // The JS boot latch owns idle → pending → ready/failed; each generation creates a new instance.
    nonisolated(unsafe) private static var application: Application?

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
        struct Metadata: Decodable { let operation: String; let context: RequestContext }
        guard let application, let frame = try? JSONDecoder().decode(Metadata.self, from: Data(bytes: metadata, count: Int(metadataCount))) else {
            let response = ServerResponse.failure("operation_failed", status: 500)
            response.body.withUnsafeBytes { chik_settle(call, Int32(response.status), $0.baseAddress, Int32($0.count)) }
            return
        }
        // Copy before suspension; every completion owns its response allocation until JS copies it.
        let input = Data(bytes: body, count: Int(bodyCount))
        Task {
            let response = await application.handle(frame.operation, body: input, context: frame.context)
            response.body.withUnsafeBytes { chik_settle(call, Int32(response.status), $0.baseAddress, Int32($0.count)) }
        }
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
#endif
