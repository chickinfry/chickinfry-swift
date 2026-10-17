import Foundation
@_spi(Conformance) import Chickinfry

final class TransportObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var sequence = 0
    private var events: [String: [JSON]] = [:]
    private var statuses: [String: Int] = [:]
    private var entered: [String: UInt64] = [:]

    func register(_ id: String) { lock.withLock { events[id] = [] } }

    func start(_ id: String) {
        lock.withLock { entered[id] = DispatchTime.now().uptimeNanoseconds; events[id] = [] }
    }

    func record(_ id: String, event: Conformance.Event) {
        lock.withLock {
            sequence += 1
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsed = (now - (entered[id] ?? now)) / 1_000_000
            events[id, default: []].append(.object([
                "sequence": .int(sequence), "callId": .string(id), "elapsedMs": .int(Int(elapsed)),
                "phase": .string(event.phase), "httpStatus": .optional(event.httpStatus),
                "readBytes": .int(event.readBytes), "retainedBytes": .int(event.retainedBytes),
                "peakRetainedBytes": .int(event.peakRetainedBytes),
            ]))
            if event.phase == "completed", let status = event.httpStatus { statuses[id] = status }
        }
    }

    func status(_ id: String) -> Int? { lock.withLock { statuses[id] } }

    func snapshot(_ id: String, after: Int) throws -> JSON {
        try lock.withLock {
            guard let values = events[id], after <= sequence else { throw ProtocolFailure.invalidReference }
            return .object([
                "callId": .string(id), "throughSequence": .int(sequence), "complete": .bool(true),
                "events": .array(values.filter { ($0["sequence"].integer ?? 0) > after }),
            ])
        }
    }
}
