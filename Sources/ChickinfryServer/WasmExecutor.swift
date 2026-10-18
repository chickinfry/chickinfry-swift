#if os(WASI)
@_spi(ExperimentalCustomExecutors) @_spi(ExperimentalScheduling) import _Concurrency
import CChickinfryExecutor

// Swift 6.4 sleep uses SchedulingExecutor before the legacy runtime hooks.
final class WasmExecutor: MainExecutor, TaskExecutor, SchedulingExecutor, @unchecked Sendable {
    static let task = WasmExecutor(isMain: false)
    static let main = WasmExecutor(isMain: true)
    nonisolated(unsafe) private static var pending: [UInt: (UnownedJob, WasmExecutor)] = [:]
    nonisolated(unsafe) private static var nextJob: UInt = 1
    private let isMain: Bool

    private init(isMain: Bool) { self.isMain = isMain }

    func enqueue(_ job: consuming ExecutorJob) { schedule(UnownedJob(job), milliseconds: 0) }
    func enqueue(_ job: UnownedJob) { schedule(job, milliseconds: 0) }

    func enqueue<C: Clock>(_ job: consuming ExecutorJob, after delay: C.Duration,
                           tolerance: C.Duration?, clock: C) {
        guard let duration = delay as? Duration else {
            preconditionFailure("Unsupported scheduling clock duration.")
        }
        let parts = duration.components
        let milliseconds = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1_000_000_000_000_000
        schedule(UnownedJob(job), milliseconds: max(0, milliseconds))
    }

    private func schedule(_ job: UnownedJob, milliseconds: Double) {
        precondition(Self.nextJob < UInt.max, "Swift job limit exceeded.")
        let id = Self.nextJob
        Self.nextJob += 1
        Self.pending[id] = (job, self)
        chik_enqueue_job(id, milliseconds)
    }

    static func run(_ id: UInt) {
        guard let (job, executor) = pending.removeValue(forKey: id) else { return }
        if executor.isMain {
            job.runSynchronously(isolatedTo: executor.asUnownedSerialExecutor(), taskExecutor: task.asUnownedTaskExecutor())
        } else {
            job.runSynchronously(on: task.asUnownedTaskExecutor())
        }
    }

    func run() throws { preconditionFailure("JavaScript owns the event loop.") }
    func stop() { preconditionFailure("JavaScript owns the event loop.") }
}

private enum WasmExecutorFactory: ExecutorFactory {
    static var mainExecutor: any MainExecutor { WasmExecutor.main }
    static var defaultExecutor: any TaskExecutor { WasmExecutor.task }
}

func installWasmExecutors() { _createExecutors(factory: WasmExecutorFactory.self) }
#endif
