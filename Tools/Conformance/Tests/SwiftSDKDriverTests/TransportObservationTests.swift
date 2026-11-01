import Foundation
import Testing
@_spi(Conformance) import Chickinfry
@testable import SwiftSDKDriver

@Test(arguments: [false, true])
func actualTransportSnapshotsKeepWatermarksAndCompletionSeparate(withStore: Bool) async throws {
    let observation = TransportObservation()
    observation.start("c:first")
    let body = try JSONEncoder().encode(["wire_value": String(repeating: "x", count: 32768),
                                        "observed_at": "2026-10-15T01:02:03Z"])
    let peer = try TestPeer(body: body, chunkSize: 1024)
    let origin = try await peer.start()
    defer { peer.stop() }
    let base = try HTTPTransport(origin: origin)
    let transport = try (withStore ? base.withSession(MemoryStore(origin: origin)) : base)
    let context = Conformance.Call(event: { event in
        if event.phase == "read" {
            #expect(event.readBytes > event.retainedBytes)
        }
        observation.record("c:first", event: event)
    }, barrier: { _, _ in }, clear: { _, _ in })
    _ = try await Conformance.$call.withValue(context) {
        try await PlainBridge(transport).call("probe.echo", input: .object(["wire_value": .string("test")]))
    }
    let result = try observation.snapshot("c:first", after: 0)
    let events = try #require(result["events"].array)
    let phases = events.compactMap { $0["phase"].string }
    #expect(phases.first == "headers")
    #expect(phases.filter { $0 == "completed" }.count == 1)
    #expect(phases.contains("reader-closed"))
    #expect(!phases.contains("cancel-requested"))
    #expect(!phases.contains("limit"))
    #expect(events.last?["readBytes"] == .int(body.count))
    #expect(events.last?["peakRetainedBytes"] == .int(body.count))
    var previous = 0
    var elapsed = 0
    for event in events {
        #expect(Set(event.object?.keys.map { $0 } ?? []) == Set([
            "sequence", "callId", "elapsedMs", "phase", "httpStatus", "readBytes", "retainedBytes", "peakRetainedBytes",
        ]))
        let sequence = try #require(event["sequence"].integer)
        let now = try #require(event["elapsedMs"].integer)
        #expect(sequence > previous)
        #expect(now >= elapsed)
        #expect(event["callId"] == .string("c:first"))
        #expect(event["httpStatus"] == .int(200))
        #expect((event["retainedBytes"].integer ?? -1) >= 0)
        #expect((event["peakRetainedBytes"].integer ?? -1) >= (event["retainedBytes"].integer ?? 0))
        previous = sequence
        elapsed = now
    }
    let watermark = try #require(result["throughSequence"].integer)
    #expect(try observation.snapshot("c:first", after: watermark)["events"] == .array([]))
    #expect(throws: ProtocolFailure.self) { try observation.snapshot("c:first", after: -1) }
    #expect(throws: ProtocolFailure.self) { try observation.snapshot("c:missing", after: 0) }
}

@Test func overflowRecordsReadThenLimitAndActualCancellation() async throws {
    let observation = TransportObservation()
    observation.start("c:overflow")
    let peer = try TestPeer(body: Data(repeating: 32, count: 2 * 1024 * 1024), chunkSize: 16384)
    let origin = try await peer.start()
    defer { peer.stop() }
    let context = Conformance.Call(event: { observation.record("c:overflow", event: $0) },
                                   barrier: { _, _ in }, clear: { _, _ in })
    do {
        let transport = try HTTPTransport(origin: origin)
        _ = try await Conformance.$call.withValue(context) {
            try await PlainBridge(transport).call("probe.echo", input: .object(["wire_value": .string("test")]))
        }
        Issue.record("An oversized response must fail")
    } catch let error as ClientError { #expect(error.code == "resource_exhausted") }
    let deadline = ContinuousClock.now + .seconds(2)
    var events: [JSON] = []
    repeat {
        events = try observation.snapshot("c:overflow", after: 0)["events"].array ?? []
        if events.contains(where: { $0["phase"] == .string("reader-closed") }) { break }
        await Task.yield()
    } while ContinuousClock.now < deadline
    let phases = events.compactMap { $0["phase"].string }
    let limit = try #require(phases.firstIndex(of: "limit"))
    #expect(phases[limit - 1] == "read")
    #expect((events[limit - 1]["readBytes"].integer ?? 0) > 1024 * 1024)
    #expect(!phases.suffix(from: limit).contains("read"))
    let requested = try #require(phases.firstIndex(of: "cancel-requested"))
    let observed = try #require(phases.firstIndex(of: "cancel-observed"))
    let closed = try #require(phases.firstIndex(of: "reader-closed"))
    #expect(limit < requested && requested < observed && observed < closed)
    #expect(phases.filter { $0 == "completed" }.count == 1)
    #expect(events.allSatisfy { ($0["peakRetainedBytes"].integer ?? Int.max) <= 1024 * 1024 })
}

@Test func advertisedObservationReturnsRealPendingAndFinalSDKEvents() async throws {
    let messages = Messages()
    let driver = Driver(credentials: [:], output: { messages.append($0) })
    func command(_ id: String, _ name: String, _ args: [String: JSON]) -> JSON {
        .object(["id": .string(id), "command": .string(name), "args": .object(args)])
    }
    try await driver.receive(command("c:hello", "handshake", [
        "protocolVersions": .array([.int(1)]), "runId": .string("run"),
        "requiredCapabilities": .array([.string("client.transport")]),
        "target": .object(["language": .string("swift"), "role": .string("sdk"), "environment": .string("native")]),
    ]))
    let hello = try await messages.wait { $0["id"] == .string("c:hello") }
    try #require(hello["error"] == .null)
    let body = try JSONEncoder().encode(["wire_value": "observed", "observed_at": "2026-10-15T01:02:03Z"])
    let peer = try TestPeer(body: body, chunkSize: 1024)
    let origin = try await peer.start()
    defer { peer.stop() }
    let common: [String: JSON] = ["caseId": .string("case"), "timeoutMs": .int(5000)]
    try await driver.receive(command("c:create", "client.create", common.merging([
        "clientRef": .string("client"), "fixture": .string("plain"), "origin": .string(origin), "requestTimeoutMs": .int(1000),
    ]) { _, new in new }))
    let created = try await messages.wait { $0["id"] == .string("c:create") }
    #expect(created["error"] == .null)
    try await driver.receive(command("c:call", "client.call", common.merging([
        "clientRef": .string("client"), "operation": .string("probe.echo"),
        "input": .object(["wire_value": .string("test")]),
    ]) { _, new in new }))
    try await driver.receive(command("c:pending", "client.observe", common.merging([
        "callId": .string("c:call"), "afterSequence": .int(0),
    ]) { _, new in new }))
    let pending = try await messages.wait { $0["id"] == .string("c:pending") }
    #expect(pending["result"]["complete"] == .bool(true))
    let called = try await messages.wait { $0["id"] == .string("c:call") }
    #expect(called["error"] == .null)
    try await driver.receive(command("c:final", "client.observe", common.merging([
        "callId": .string("c:call"), "afterSequence": .int(0),
    ]) { _, new in new }))
    let final = try await messages.wait { $0["id"] == .string("c:final") }
    let events = try #require(final["result"]["events"].array)
    #expect(events.contains { $0["phase"] == .string("read") && $0["readBytes"] == .int(body.count) })
    #expect(events.last?["phase"] == .string("completed"))
    #expect(events.last?["httpStatus"] == .int(200))
    await driver.shutdown()
}

@Test func aFailedConnectionDoesNotInventCancellation() async throws {
    let observation = TransportObservation()
    observation.start("c:failed")
    let context = Conformance.Call(event: { observation.record("c:failed", event: $0) },
                                   barrier: { _, _ in }, clear: { _, _ in })
    // An empty response list closes the connection without sending HTTP headers.
    let peer = try TestPeer(responses: [], chunkSize: 1)
    let origin = try await peer.start()
    defer { peer.stop() }
    let transport = try HTTPTransport(origin: origin, timeout: 1)
    do {
        _ = try await Conformance.$call.withValue(context) {
            try await PlainBridge(transport).call("probe.echo", input: .object(["wire_value": .string("test")]))
        }
        Issue.record("A failed connection must fail")
    } catch let error as ClientError { #expect(error.code == "unavailable") }
    let events = try #require(observation.snapshot("c:failed", after: 0)["events"].array)
    #expect(!events.contains { $0["phase"] == .string("cancel-requested") || $0["phase"] == .string("cancel-observed") })
    #expect(events.contains { $0["phase"] == .string("reader-closed") })
    #expect(events.last?["phase"] == .string("completed"))
}
