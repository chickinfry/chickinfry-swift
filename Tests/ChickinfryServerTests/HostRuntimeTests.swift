#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@_spi(Generated) @testable import ChickinfryServer

private let ok = ServerResponse(status: 200, body: Data("{}".utf8))
private func bytes(_ value: String) -> Data { Data(value.utf8) }

private actor UncooperativeGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}

private struct Harness: Sendable {
    let runtime: HostRuntime
    let calls: AsyncStream<HostCall>
    let responses: AsyncStream<Int32>
    let results: AsyncStream<ServerResponse>

    init() {
        let calls = AsyncStream<HostCall>.makeStream()
        let responses = AsyncStream<Int32>.makeStream()
        let results = AsyncStream<ServerResponse>.makeStream()
        self.calls = calls.stream
        self.responses = responses.stream
        self.results = results.stream
        runtime = HostRuntime(send: { calls.continuation.yield($0) }, settle: { id, response in
            responses.continuation.yield(id)
            results.continuation.yield(response)
        })
    }

    func reply(_ call: HostCall, _ value: String = "{}", success: Bool = true) async {
        await runtime.receive(call.id, succeeded: success, bytes: bytes(value))
    }
}

@Test func hostContinuationsAreOneShotAndRequestsStayIsolated() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    func response() async -> Int32? {
        await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                var responses = h.responses.makeAsyncIterator()
                return await responses.next()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            defer { group.cancelAll() }
            return await group.next() ?? nil
        }
    }
    try await h.runtime.start(1, rid: 4_294_967_300) {
        let host = try #require(HostRequest.current)
        let result = try await host.database(bytes(#"{"op":"query","sql":"slow","params":[]}"#))
        #expect(result == bytes(#"{"rows":[{"value":"first"}]}"#))
        return ok
    }
    let slow = try #require(await calls.next())
    #expect(try HostFrame.decode(slow.bytes)["rid"] == .integer(4_294_967_300))
    try await h.runtime.start(2, rid: 8) { ok }
    let fastFinish = try #require(await calls.next())
    #expect(fastFinish.channel == .finish)
    #expect(try HostFrame.decode(fastFinish.bytes)["rid"] == .integer(8))
    #expect(await h.runtime.snapshot(2)?.cleanupComplete == false)
    await h.reply(fastFinish)
    let active = try #require(await h.runtime.snapshot(1))
    #expect(active.phase == .running)
    #expect(await response() == 2)
    await h.reply(slow, #"{"rows":[{"value":"first"}]}"#)
    await h.reply(slow, #"{"rows":[{"value":"wrong"}]}"#)
    let finish = try #require(await calls.next())
    await h.reply(finish)
    #expect(await response() == 1)
    #expect(await h.runtime.snapshot(1) == nil)
}

@Test func transactionSealsBeforeCommitAndPreservesUnknown() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    try await h.runtime.start(1, rid: 99) {
        let host = try #require(HostRequest.current)
        _ = try await host.database(bytes(#"{"op":"begin"}"#))
        _ = try await host.database(bytes(#"{"op":"exec","lease":41,"sql":"write","params":[]}"#))
        do { _ = try await host.database(bytes(#"{"op":"commit","lease":41}"#)); Issue.record("Commit must fail") }
        catch { #expect((error as? HostFailure)?.code == "commit_unknown") }
        for frame in [#"{"op":"exec","lease":41,"sql":"late","params":[]}"#, #"{"op":"rollback","lease":41}"#, #"{"op":"commit","lease":41}"#] {
            await #expect(throws: HostFailure.self) { _ = try await host.database(bytes(frame)) }
        }
        return ok
    }
    let begin = try #require(await calls.next())
    await h.reply(begin, #"{"lease":41}"#)
    let exec = try #require(await calls.next())
    #expect(try HostFrame.decode(exec.bytes)["lease"] == .integer(41))
    await h.reply(exec, #"{"rows":[]}"#)
    let commit = try #require(await calls.next())
    #expect(await h.runtime.snapshot(1)?.transaction == .committing(41))
    await h.reply(commit, #"{"error":"commit_unknown"}"#)
    let finish = try #require(await calls.next())
    #expect(finish.channel == .finish)
    #expect(await h.runtime.snapshot(1)?.transaction == .commitUnknown)
    await h.reply(finish)
    #expect(await responses.next() == 1)
}

@Test func cancellationBlocksNewIOAndWaitsForTaskAndHostCleanup() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    let gate = UncooperativeGate()
    try await h.runtime.start(1, rid: 10) {
        let host = try #require(HostRequest.current)
        do { _ = try await host.database(bytes(#"{"op":"begin"}"#)) }
        catch is CancellationError {}
        await #expect(throws: CancellationError.self) {
            _ = try await host.database(bytes(#"{"op":"query","sql":"forbidden","params":[]}"#))
        }
        await gate.wait()
        return ok
    }
    let begin = try #require(await calls.next())
    await h.runtime.cancel(1)
    let finish = try #require(await calls.next())
    #expect(finish.channel == .finish)
    #expect(try HostFrame.decode(finish.bytes)["cancel"] == .bool(true))
    await h.reply(finish)
    #expect(await h.runtime.snapshot(1)?.cleanupComplete == true)
    #expect(await h.runtime.snapshot(1)?.phase == .stopping)
    await h.reply(begin, #"{"lease":76}"#)
    #expect(await h.runtime.snapshot(1)?.transaction == .discarded)
    await gate.open()
    #expect(await responses.next() == 1)
    #expect(await h.runtime.snapshot(1) == nil)
}

private struct CommitCase: Sendable {
    let transmission: CommitTransmission
    let responseComplete: Bool
    let outcomeUnknown: Bool?
}

@Test(arguments: [
    CommitCase(transmission: .notStarted, responseComplete: false, outcomeUnknown: false),
    CommitCase(transmission: .mayHaveStarted, responseComplete: false, outcomeUnknown: true),
    CommitCase(transmission: .unobserved, responseComplete: false, outcomeUnknown: nil),
    CommitCase(transmission: .mayHaveStarted, responseComplete: true, outcomeUnknown: false),
    CommitCase(transmission: .unobserved, responseComplete: true, outcomeUnknown: false),
])
private func cancellationUsesCommitEvidenceRatherThanMethodEntry(_ facts: CommitCase) async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    try await h.runtime.start(1, rid: 5) {
        let host = try #require(HostRequest.current)
        _ = try await host.database(bytes(#"{"op":"begin"}"#))
        do { _ = try await host.database(bytes(#"{"op":"commit","lease":7}"#)) }
        catch is CancellationError {}
        return ok
    }
    let begin = try #require(await calls.next())
    await h.reply(begin, #"{"lease":7}"#)
    let commit = try #require(await calls.next())
    await h.runtime.observeCommit(commit.id, transmission: facts.transmission, responseComplete: facts.responseComplete)
    if facts.transmission == .mayHaveStarted {
        await h.runtime.observeCommit(commit.id, transmission: .notStarted, responseComplete: false)
    }
    await h.runtime.cancel(1)
    let finish = try #require(await calls.next())
    let snapshot = try #require(await h.runtime.snapshot(1))
    #expect(snapshot.outcomeUnknown == facts.outcomeUnknown)
    #expect(snapshot.transaction == (facts.outcomeUnknown == true ? .commitUnknown : .discarded))
    await h.reply(commit)
    #expect(await h.runtime.snapshot(1)?.transaction == snapshot.transaction)
    await h.reply(finish)
    #expect(await responses.next() == 1)
}

@Test(arguments: ["binding_unavailable", "log_failed"])
func crossChannelCommitErrorPreservesUncertainty(_ code: String) async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    try await h.runtime.start(1, rid: 5) {
        let host = try #require(HostRequest.current)
        _ = try await host.database(bytes(#"{"op":"begin"}"#))
        _ = try await host.database(bytes(#"{"op":"commit","lease":7}"#))
        return ok
    }
    let begin = try #require(await calls.next())
    await h.reply(begin, #"{"lease":7}"#)
    let commit = try #require(await calls.next())
    #expect(try HostFrame.decode(commit.bytes)["op"] == .string("commit"))
    await h.runtime.observeCommit(commit.id, transmission: .mayHaveStarted, responseComplete: false)
    await h.reply(commit, "{\"error\":\"\(code)\"}")
    let finish = try #require(await calls.next())
    #expect(finish.channel == .finish)
    let snapshot = try #require(await h.runtime.snapshot(1))
    #expect(snapshot.transaction == .commitUnknown)
    #expect(snapshot.outcomeUnknown == true)
    await h.reply(commit)
    #expect(await h.runtime.snapshot(1)?.transaction == snapshot.transaction)
    await h.reply(finish)
    #expect(await responses.next() == 1)
}

@Test func handlerReturningWithPendingCommitSettlesAsFailure() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var results = h.results.makeAsyncIterator()
    let gate = UncooperativeGate()
    let children = AsyncStream<Task<Void, Never>>.makeStream()
    try await h.runtime.start(1, rid: 5) {
        children.continuation.yield(Task {
            do {
                let host = try #require(HostRequest.current)
                _ = try await host.database(bytes(#"{"op":"begin"}"#))
                _ = try await host.database(bytes(#"{"op":"commit","lease":7}"#))
            } catch {}
        })
        await gate.wait()
        return ok
    }
    let begin = try #require(await calls.next())
    await h.reply(begin, #"{"lease":7}"#)
    let commit = try #require(await calls.next())
    #expect(try HostFrame.decode(commit.bytes)["op"] == .string("commit"))
    await h.runtime.observeCommit(commit.id, transmission: .mayHaveStarted, responseComplete: false)
    await gate.open()
    let finish = try #require(await calls.next())
    #expect(finish.channel == .finish)
    #expect(try HostFrame.decode(finish.bytes)["cancel"] == .bool(true))
    #expect(await h.runtime.snapshot(1)?.transaction == .commitUnknown)
    #expect(await h.runtime.snapshot(1)?.outcomeUnknown == true)
    await h.reply(finish)
    let response = try #require(await results.next())
    #expect(response.status == 500)
    #expect(response.body == bytes(#"{"error":"operation_failed"}"#))
    var tasks = children.stream.makeAsyncIterator()
    let child = try #require(await tasks.next())
    await child.value
}

@Test func hostFramesRejectDuplicateKeysAndMalformedEnvelopes() throws {
    for value in [#"{"lease":1,"lease":2}"#, #"{"lease":1,"le\u0061se":2}"#, #"{"rows":[{"id":1,"id":2}]}"#, "{}{}", "{\"x\":NaN}"] {
        #expect(throws: (any Error).self) { _ = try HostFrame.decode(bytes(value)) }
    }
    #expect(throws: (any Error).self) { _ = try HostFrame.decode(Data([123, 34, 120, 34, 58, 34, 255, 34, 125])) }
    for (operation, response) in [
        ("begin", #"{"lease":0}"#), ("begin", #"{"lease":9007199254740992}"#),
        ("begin", #"{"lease":1.0000000000000001}"#),
        ("query", #"{"rows":[],"error":"database_failed"}"#), ("query", #"{"rows":[1]}"#),
        ("query", #"{"rows":[],"extra":true}"#), ("commit", #"{"ok":true}"#),
        ("env", #"{"value":3}"#), ("log", #"{"error":"private diagnostics"}"#),
        ("query", #"{"error":"binding_unavailable"}"#), ("begin", #"{"error":"log_failed"}"#),
        ("exec", #"{"error":"binding_unavailable"}"#), ("rollback", #"{"error":"log_failed"}"#),
        ("env", #"{"error":"database_failed"}"#), ("env", #"{"error":"23505"}"#),
        ("env", #"{"error":"commit_unknown"}"#), ("env", #"{"error":"log_failed"}"#),
        ("log", #"{"error":"binding_unavailable"}"#), ("log", #"{"error":"23505"}"#),
        ("log", #"{"error":"commit_unknown"}"#), ("finish", #"{"error":"invalid_host_call"}"#)
    ] {
        #expect(throws: (any Error).self) { _ = try HostFrame.response(operation, bytes: bytes(response)) }
    }
    for number in [
        "9007199254740991.1", "-9007199254740991.1", "90071992547409911e-1",
        "9007199254740990.1", "1.0000000000000001", "-1.0000000000000001",
        "9007199254740991.0000000000000000000000000000000000000001",
        "1e-999", "-1e-999", "1e999999999999999999999", "1e-999999999999999999999"
    ] {
        #expect(throws: (any Error).self) {
            _ = try HostFrame.response("query", bytes: bytes("{\"rows\":[{\"value\":\(number)}]}"))
        }
        #expect(throws: (any Error).self) {
            _ = try HostFrame.request(.database, bytes: bytes("{\"op\":\"query\",\"sql\":\"SELECT $1\",\"params\":[\(number)]}"), rid: 1)
        }
    }
    for (number, expected) in [
        ("9007199254740991", HostValue.integer(9_007_199_254_740_991)),
        ("-9007199254740991", .integer(-9_007_199_254_740_991)),
        ("90071992547409910e-1", .integer(9_007_199_254_740_991)),
        ("0", .integer(0)), ("-0.0e-999", .integer(0)),
        ("1.5", .number(1.5)), ("0.1", .number(0.1)), ("0.000001", .number(0.000001)),
        ("8.5e15", .integer(8_500_000_000_000_000)),
        ("1e-300", .number(1e-300)), ("5e-324", .number(Double.leastNonzeroMagnitude))
    ] {
        #expect(try HostFrame.response("query", bytes: bytes("{\"rows\":[{\"value\":\(number)}]}"))["rows"] == .array([.object(["value": expected])]))
        let (request, _) = try HostFrame.request(.database, bytes: bytes("{\"op\":\"query\",\"sql\":\"SELECT $1\",\"params\":[\(number)]}"), rid: 1)
        #expect(try HostFrame.decode(request)["params"] == .array([expected]))
    }
    for (operation, code) in [
        ("query", "database_failed"), ("begin", "23505"), ("exec", "invalid_host_call"),
        ("commit", "commit_unknown"), ("rollback", "database_failed"),
        ("env", "binding_unavailable"), ("env", "invalid_host_call"),
        ("log", "log_failed"), ("log", "invalid_host_call")
    ] {
        #expect(try HostFrame.response(operation, bytes: bytes("{\"error\":\"\(code)\"}"))["error"] == .string(code))
    }
}

@Test func deadlineUsesTheSameRequestCancellationAndRetainedAuthorityCloses() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    let retained = AsyncStream<HostRequest>.makeStream()
    var aliases = retained.stream.makeAsyncIterator()
    try await h.runtime.start(1, rid: 70, deadlineNanoseconds: 20_000_000) {
        let host = try #require(HostRequest.current)
        retained.continuation.yield(host)
        do { _ = try await host.database(bytes(#"{"op":"query","sql":"slow","params":[]}"#)) }
        catch is CancellationError {}
        return ok
    }
    let query = try #require(await calls.next())
    let alias = try #require(await aliases.next())
    let finish = try #require(await calls.next())
    #expect(try HostFrame.decode(finish.bytes)["cancel"] == .bool(true))
    await h.reply(finish)
    #expect(await responses.next() == 1)
    await h.reply(query, #"{"rows":[]}"#)
    await #expect(throws: CancellationError.self) {
        _ = try await alias.database(bytes(#"{"op":"query","sql":"late","params":[]}"#))
    }
}

@Test func beginGuardRollbackAndSuccessfulCommitKeepFinality() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    var results = h.results.makeAsyncIterator()
    try await h.runtime.start(1, rid: 11) {
        let host = try #require(HostRequest.current)
        async let first = host.database(bytes(#"{"op":"begin"}"#))
        while await h.runtime.snapshot(1)?.transaction == .idle { await Task.yield() }
        await #expect(throws: HostFailure.self) { _ = try await host.database(bytes(#"{"op":"begin"}"#)) }
        _ = try await first
        _ = try await host.database(bytes(#"{"op":"rollback","lease":3}"#))
        _ = try await host.database(bytes(#"{"op":"begin"}"#))
        _ = try await host.database(bytes(#"{"op":"commit","lease":4}"#))
        return ok
    }
    let begin = try #require(await calls.next())
    #expect(await h.runtime.snapshot(1)?.transaction == .beginning)
    await h.reply(begin, #"{"lease":3}"#)
    let rollback = try #require(await calls.next())
    #expect(await h.runtime.snapshot(1)?.transaction == .rollingBack(3))
    await h.reply(rollback)
    let second = try #require(await calls.next())
    await h.reply(second, #"{"lease":4}"#)
    let commit = try #require(await calls.next())
    await h.reply(commit)
    let finish = try #require(await calls.next())
    #expect(await h.runtime.snapshot(1)?.transaction == .committed)
    await h.runtime.cancel(1)
    #expect(await h.runtime.snapshot(1)?.transaction == .committed)
    #expect(await h.runtime.snapshot(1)?.outcomeUnknown == false)
    let cancelledFinish = try #require(await calls.next())
    await h.reply(finish)
    #expect(await h.runtime.snapshot(1)?.cleanupComplete == false)
    await h.reply(cancelledFinish)
    #expect(await responses.next() == 1)
    #expect(await results.next()?.status == 200)
}

@Test func invalidHostReplyStopsOnlyItsOwnerAndCleanupFailureStaysIncomplete() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    try await h.runtime.start(1, rid: 51) {
        let host = try #require(HostRequest.current)
        await #expect(throws: (any Error).self) { _ = try await host.database(bytes(#"{"op":"begin"}"#)) }
        return ok
    }
    let begin = try #require(await calls.next())
    await h.reply(begin, #"{"lease":0}"#)
    let finish = try #require(await calls.next())
    await h.reply(finish, "{}", success: false)
    #expect(await h.runtime.snapshot(1)?.phase == .stopping)
    #expect(await h.runtime.snapshot(1)?.cleanupComplete == false)
    try await h.runtime.start(2, rid: 52) { ok }
    let other = try #require(await calls.next())
    #expect(try HostFrame.decode(other.bytes)["rid"] == .integer(52))
    await h.reply(other)
    #expect(await responses.next() == 2)
    await h.reply(begin, #"{"lease":20}"#)
    #expect(await h.runtime.snapshot(1)?.transaction == .discarded)
}

@Test func retainedAliasCannotStartIOFromAnUncancelledTask() async throws {
    let calls = AsyncStream<HostCall>.makeStream()
    let aliases = AsyncStream<HostRequest>.makeStream()
    let gate = UncooperativeGate()
    let acknowledgements = AsyncStream<Void>.makeStream()
    let responses = AsyncStream<Void>.makeStream()
    let runtime = HostRuntime(send: { calls.continuation.yield($0) }, settle: { _, _ in responses.continuation.yield(()) })
    let host = Task {
        for await call in calls.stream {
            let reply = call.channel == .database ? #"{"rows":[]}"# : "{}"
            await runtime.receive(call.id, succeeded: true, bytes: bytes(reply))
            if call.channel == .finish { acknowledgements.continuation.yield(()) }
        }
    }
    try await runtime.start(1, rid: 71) {
        aliases.continuation.yield(try #require(HostRequest.current))
        await gate.wait()
        return ok
    }
    var iterator = aliases.stream.makeAsyncIterator()
    let alias = try #require(await iterator.next())
    await runtime.cancel(1)
    var cleanup = acknowledgements.stream.makeAsyncIterator()
    _ = await cleanup.next()
    await #expect(throws: CancellationError.self) {
        _ = try await alias.database(bytes(#"{"op":"query","sql":"forbidden","params":[]}"#))
    }
    await gate.open()
    var settled = responses.stream.makeAsyncIterator()
    _ = await settled.next()
    calls.continuation.finish()
    await host.value
}

@Test func cancellationBeforeTaskRegistrationSkipsTheHandler() async throws {
    let h = Harness()
    var calls = h.calls.makeAsyncIterator()
    var responses = h.responses.makeAsyncIterator()
    try await h.runtime.start(1, rid: 82, cancelled: true) {
        Issue.record("A cancelled request must not enter the handler")
        return ok
    }
    let finish = try #require(await calls.next())
    #expect(finish.channel == .finish)
    await h.reply(finish)
    #expect(await responses.next() == 1)
}
