import Foundation
import Network
import Testing
@_spi(Conformance) import Chickinfry
@testable import SwiftSDKDriver

private final class Oracle: @unchecked Sendable {
    private let lock = NSLock()
    private var comparisons: [(Int, Int)] = []
    private var owners: [UUID: Conformance.Buffers] = [:]
    private var leases: [UUID: @Sendable () -> Void] = [:]
    private var order: [UUID] = []
    private var independentPeak = 0
    private var completedPeak = 0
    private var completedRetained = 0

    func inspect(_ buffers: Conformance.Buffers, _ event: Conformance.Event) {
        lock.withLock {
            if owners[buffers.exchange] == nil { order.append(buffers.exchange) }
            owners[buffers.exchange] = buffers
            leases[buffers.exchange] = buffers.holdOwner()
            let actual = owners.values.reduce(0) { $0 + $1.responseBytes + $1.accumulatedBytes }
            comparisons.append((actual, event.retainedBytes))
            independentPeak = max(independentPeak, actual)
        }
    }

    func release(reverse: Bool, keepingLast: Bool = false) {
        let ids = lock.withLock {
            let ids = keepingLast ? Array(order.dropLast()) : order
            return reverse ? Array(ids.reversed()) : ids
        }
        for id in ids { lock.withLock { _ = leases.removeValue(forKey: id) } }
    }

    var liveBytes: Int {
        lock.withLock { owners.values.reduce(0) { $0 + $1.responseBytes + $1.accumulatedBytes } }
    }

    var exchangeCount: Int { lock.withLock { owners.count } }

    func event(_ event: Conformance.Event) {
        if event.phase == "completed" {
            lock.withLock {
                completedRetained = owners.values.reduce(0) { $0 + $1.responseBytes + $1.accumulatedBytes }
                comparisons.append((completedRetained, event.retainedBytes))
                completedPeak = event.peakRetainedBytes
            }
        }
    }

    func verify(releasedBeforeCompletion: Bool = false) {
        lock.withLock {
            #expect(!comparisons.isEmpty)
            for (actual, reported) in comparisons { #expect(actual == reported) }
            #expect(independentPeak == completedPeak)
            if releasedBeforeCompletion { #expect(independentPeak > completedRetained) }
        }
    }
}

final class TestPeer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "conformance.oracle.peer")
    private let responses: [(Int, Data)]
    private let chunkSize: Int
    private var next = 0

    init(body: Data, chunkSize: Int) throws {
        responses = [(200, body)]
        self.chunkSize = chunkSize
        listener = try NWListener(using: .tcp, on: .any)
    }

    init(responses: [(Int, Data)], chunkSize: Int) throws {
        self.responses = responses
        self.chunkSize = chunkSize
        listener = try NWListener(using: .tcp, on: .any)
    }

    func start() async throws -> String {
        listener.newConnectionHandler = { connection in
            let index = self.next
            self.next += 1
            connection.start(queue: self.queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, _, error in
                guard error == nil, !self.responses.isEmpty else { connection.cancel(); return }
                let (status, body) = self.responses[min(index, self.responses.count - 1)]
                let header = Data("HTTP/1.1 \(status) Test\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                connection.send(content: header, completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                    else { self.send(connection, body: body, offset: 0) }
                })
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(returning: "http://127.0.0.1:\(self.listener.port!.rawValue)")
                case .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    var connectionCount: Int { queue.sync { next } }
    func stop() { listener.newConnectionHandler = nil; listener.cancel() }

    private func send(_ connection: NWConnection, body: Data, offset: Int) {
        guard offset < body.count else {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                            completion: .contentProcessed { error in
                if error != nil { connection.cancel() }
                else { self.drain(connection) }
            })
            return
        }
        let end = min(body.count, offset + chunkSize)
        connection.send(content: body.subdata(in: offset..<end), completion: .contentProcessed { error in
            if error != nil { connection.cancel() }
            else { self.send(connection, body: body, offset: end) }
        })
    }

    // Read through the peer's close so unread request bytes cannot reset the response.
    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { _, _, complete, error in
            if complete || error != nil { connection.cancel() }
            else { self.drain(connection) }
        }
    }
}

@Test func testRetainedBytesIncludesEveryOwnedBuffer() async throws {
    for (size, chunk) in [(7, 1), (4096, 113), (65537, 16384)] {
        let body = try JSONEncoder().encode(["wire_value": String(repeating: "z", count: size),
                                            "observed_at": "2026-10-15T01:02:03.123456789Z"])
        let peer = try TestPeer(body: body, chunkSize: chunk)
        let origin = try await peer.start()
        let oracle = Oracle()
        let context = Conformance.Call(event: { oracle.event($0) }, barrier: { _, _ in }, clear: { _, _ in },
                                       buffers: { oracle.inspect($0, $1) })
        let transport = try HTTPTransport(origin: origin)
        let result = try await Conformance.$call.withValue(context) {
            try await PlainBridge(transport).call("probe.echo", input: .object(["wire_value": .string("oracle")]))
        }
        #expect(result["wire_value"]?.string?.utf8.count == size)
        oracle.verify()
        oracle.release(reverse: size % 2 == 0)
        await expectReleased(oracle, context: context)
        peer.stop()
    }
    for reverse in [false, true] { try await checkPreviousExchangeOwners(reverse: reverse) }
}

private func expectReleased(_ oracle: Oracle, context: Conformance.Call) async {
    let end = DispatchTime.now().uptimeNanoseconds + 2_000_000_000
    while DispatchTime.now().uptimeNanoseconds < end {
        if oracle.liveBytes == 0 && context.retainedBytes == 0 { return }
        await Task.yield()
    }
    #expect(oracle.liveBytes == 0)
    #expect(context.retainedBytes == 0)
}

private func oracleToken() -> String {
    Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func checkPreviousExchangeOwners(reverse: Bool) async throws {
    let refresh = try JSONEncoder().encode([
        "access_token": oracleToken(), "refresh_token": oracleToken(),
        "expires_at": "2026-10-15T01:02:03Z", "refresh_expires_at": "2026-11-15T01:02:03Z",
        "user_id": "user", "session_id": "session",
    ])
    let body = try JSONEncoder().encode(["wire_value": String(repeating: "z", count: reverse ? 8192 : 127),
                                        "observed_at": "2026-10-15T01:02:03.123456789Z"])
    let peer = try TestPeer(responses: [(401, Data("{\"error\":\"invalid_token\"}".utf8)), (200, refresh), (200, body)], chunkSize: reverse ? 97 : 4096)
    let origin = try await peer.start()
    let store = try MemoryStore(origin: origin)
    try await store.save(SessionRecord(origin: origin, accessToken: oracleToken(), refreshToken: oracleToken(),
                                      expiresAt: "2026-10-15T01:02:03Z", refreshExpiresAt: "2026-11-15T01:02:03Z",
                                      userID: "user", sessionID: "session"))
    let oracle = Oracle()
    let context = Conformance.Call(event: { oracle.event($0) }, barrier: { _, _ in }, clear: { _, _ in },
                                   buffers: { buffers, event in
                                       oracle.inspect(buffers, event)
                                       if oracle.exchangeCount == 3 && buffers.responseBytes > 0 {
                                           oracle.release(reverse: reverse, keepingLast: true)
                                       }
                                   })
    let transport = try HTTPTransport(origin: origin).withSession(store)
    _ = try await Conformance.$call.withValue(context) {
        try await AuthBridge(transport).call("probe.echo", input: .object(["wire_value": .string("oracle")]))
    }
    #expect(oracle.exchangeCount == 3)
    oracle.verify(releasedBeforeCompletion: true)
    oracle.release(reverse: reverse)
    await expectReleased(oracle, context: context)
    await store.coordinator.conformanceShutdown()
    peer.stop()
}
