import Foundation
import Testing
@testable import Chickinfry

private func randomToken() -> String {
    String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(43))
}

private func record(_ origin: String) throws -> SessionRecord {
    try SessionRecord(origin: origin, accessToken: randomToken(), refreshToken: randomToken(),
                      expiresAt: "2026-10-15T01:02:03.123456789Z", refreshExpiresAt: "2026-11-15T01:02:03.123456789Z",
                      userID: UUID().uuidString, sessionID: UUID().uuidString)
}

private func wire(_ record: SessionRecord) throws -> Data {
    try JSONEncoder().encode([
        "access_token": record.accessToken, "refresh_token": record.refreshToken,
        "expires_at": record.expiresAt, "refresh_expires_at": record.refreshExpiresAt,
        "user_id": record.userID, "session_id": record.sessionID,
    ])
}

private func sameRecord(_ actual: SessionRecord, _ expected: SessionRecord) -> Bool {
    actual.credential == expected.credential && actual.expiresAt == expected.expiresAt
        && actual.refreshExpiresAt == expected.refreshExpiresAt
        && actual.userID == expected.userID && actual.sessionID == expected.sessionID
}

private let unauthorized = Data("{\"error\":\"invalid_token\"}".utf8)

private func waitForFlight(_ coordinator: SessionCoordinator, count: Int, server: LoopbackServer) async -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
    while DispatchTime.now().uptimeNanoseconds < deadline {
        if await coordinator.waitingCount >= count { return true }
        // A broken merger must produce a numerical failure, not a hung barrier.
        if await server.log.requests.filter({ $0.path == "/auth.refresh" }).count >= count { return false }
        await Task.yield()
    }
    return false
}

@Test func testStoredSessionRefreshesOnce() async throws {
    let gate = PeerGate()
    let oldAccess = randomToken()
    let newAccess = randomToken()
    let newRefresh = randomToken()
    let refreshed = try JSONEncoder().encode([
        "access_token": newAccess, "refresh_token": newRefresh,
        "expires_at": "2026-10-15T01:02:03.123456789Z", "refresh_expires_at": "2026-11-15T01:02:03Z",
        "user_id": UUID().uuidString, "session_id": UUID().uuidString,
    ])
    let server = try LoopbackServer(responder: { request in
        if request.path == "/auth.refresh" { return .gatedReply(200, refreshed, gate) }
        return request.headers["authorization"] == "Bearer " + oldAccess
            ? .reply(401, unauthorized) : .reply(200, validBody)
    })
    let store = try MemorySessionStore(origin: server.origin)
    let old = try SessionRecord(origin: server.origin, accessToken: oldAccess, refreshToken: randomToken(),
                                expiresAt: "original", refreshExpiresAt: "original", userID: "user", sessionID: "session")
    try await store.save(old)
    let transport = try ClientTransport(origin: server.origin).withSession(store)
    let first = Task { try await transport.invoke("notes.write", input: Payload(value: "same"), as: Payload.self) }
    let second = Task { try await transport.invoke("notes.write", input: Payload(value: "same"), as: Payload.self) }
    let joined = await waitForFlight(store.coordinator, count: 2, server: server)
    await gate.open()
    let outputs = try await [first.value, second.value]
    #expect(joined)
    #expect(outputs.allSatisfy { $0.value == "ok" })
    let requests = await server.log.requests
    #expect(requests.filter { $0.path == "/auth.refresh" }.count == 1)
    #expect(requests.filter { $0.path == "/notes.write" }.count == 4)
    #expect(Set(requests.filter { $0.path == "/notes.write" }.map(\.body)).count == 1)
    let refresh = try #require(requests.first { $0.path == "/auth.refresh" })
    let input = try JSONDecoder().decode([String: String].self, from: refresh.body)
    let credentialPreserved = input["refresh_token"] == old.refreshToken && refresh.headers["authorization"] == nil
    #expect(credentialPreserved)
    let saved = try #require(await store.load())
    let savedCorrectly = saved.accessToken == newAccess && saved.refreshToken == newRefresh
    #expect(savedCorrectly)
    #expect(saved.expiresAt == "2026-10-15T01:02:03.123456789Z")
    await server.stop()
}

@Test func testRetried401DoesNotRefreshAgain() async throws {
    let refreshed = try record("https://example.com")
    try await withPeer([.reply(401, unauthorized), .reply(200, try wire(refreshed)),
                        .reply(401, unauthorized), .reply(200, try wire(refreshed)), .reply(200, validBody)]) { server in
        let store = try MemorySessionStore(origin: server.origin)
        try await store.save(record(server.origin))
        let transport = try ClientTransport(origin: server.origin).withSession(store)
        await expectFailure("invalid_token", status: 401) {
            let _: Payload = try await transport.invoke("notes.write", input: Empty())
        }
        #expect(await server.log.requests.map(\.path) == ["/notes.write", "/auth.refresh", "/notes.write"])
    }
}

@Test func testUncertainRefreshIsNotReused() async throws {
    let timeoutGate = PeerGate()
    let cases: [(PeerResponse, String, Int?)] = [
        (.reply(429, Data("{\"error\":\"rate_limited\"}".utf8)), "rate_limited", 429),
        (.reply(500, Data("{\"error\":\"operation_failed\"}".utf8)), "operation_failed", 500),
        (.reply(201, Data("{}".utf8)), "invalid_response", 201),
        (.disconnect, "transport_error", nil),
        (.gatedReply(200, validBody, timeoutGate), "timeout", nil),
        (.reply(401, Data(repeating: 32, count: 1024 * 1024 + 1)), "response_too_large", 401),
    ]
    for (response, code, status) in cases {
        try await withPeer([.reply(401, unauthorized), response, .reply(401, unauthorized), .reply(200, validBody)]) { server in
            let store = try MemorySessionStore(origin: server.origin)
            let original = try record(server.origin)
            try await store.save(original)
            let transport = try ClientTransport(origin: server.origin, timeout: 30).withSession(store)
            let call = Task { try await transport.invoke("notes.write", input: Empty(), as: Payload.self) }
            await server.log.waitForRequests(2)
            await expectFailure(code, status: status) { _ = try await call.value }
            if code == "timeout" { await timeoutGate.open() }
            let saved = try await store.load()
            let originalPreserved = saved.map { sameRecord($0, original) } ?? false
            #expect(originalPreserved)
            // Saving the same credential must not reset its unknown consumption result.
            try await store.save(original)
            await expectFailure("invalid_token", status: 401) {
                let _: Payload = try await transport.invoke("notes.write", input: Empty())
            }
            #expect(await server.log.requests.filter { $0.path == "/auth.refresh" }.count == 1)
            #expect(await server.log.requests.filter { $0.path == "/notes.write" }.count <= 2)
        }
    }
}

@Test func testDeadlineIsNotResetAcrossRefreshStages() async throws {
    let original = try record("http://127.0.0.1")
    let refreshed = try wire(record("http://127.0.0.1"))
    let originalGate = PeerGate()
    let retryGate = PeerGate()
    let server = try LoopbackServer(responder: { request in
        if request.path == "/auth.refresh" { return .reply(200, refreshed) }
        return request.headers["authorization"] == "Bearer " + original.accessToken
            ? .gatedReply(401, unauthorized, originalGate) : .gatedReply(200, validBody, retryGate)
    })
    let store = try MemorySessionStore(origin: server.origin)
    try await store.save(SessionRecord(origin: server.origin, accessToken: original.accessToken,
                                      refreshToken: original.refreshToken, expiresAt: original.expiresAt,
                                      refreshExpiresAt: original.refreshExpiresAt,
                                      userID: original.userID, sessionID: original.sessionID))
    let transport = try ClientTransport(origin: server.origin, timeout: 30).withSession(store)
    let call = Task { try await transport.invoke("posts.echo", input: Empty(), as: Payload.self) }
    await server.log.waitForRequests(1)
    try await Task.sleep(nanoseconds: 15_000_000_000)
    await originalGate.open()
    await server.log.waitForRequests(3)
    // The retry arrives with ample time left, but its reply crosses the original deadline.
    let release = Task {
        try? await Task.sleep(nanoseconds: 20_000_000_000)
        await retryGate.open()
    }
    await expectFailure("timeout", status: nil) { _ = try await call.value }
    await release.value
    #expect(await server.log.requests.map(\.path) == ["/posts.echo", "/auth.refresh", "/posts.echo"])
    await server.stop()
}

@Test func testLate401AfterUncertainRefreshUsesNewLogin() async throws {
    let gate = PeerGate()
    try await withPeer([.gatedReply(401, unauthorized, gate), .reply(401, unauthorized),
                        .disconnect, .reply(200, validBody)]) { server in
        let store = try MemorySessionStore(origin: server.origin)
        try await store.save(record(server.origin))
        let transport = try ClientTransport(origin: server.origin).withSession(store)
        let late = Task { try await transport.invoke("posts.echo", input: Empty(), as: Payload.self) }
        await server.log.waitForRequests(1)
        await expectFailure("transport_error", status: nil) {
            let _: Payload = try await transport.invoke("posts.echo", input: Empty())
        }
        let newLogin = try record(server.origin)
        try await store.save(newLogin)
        await gate.open()
        let result = await late.result
        let succeeded: Bool
        switch result {
        case .success(let output): succeeded = output.value == "ok"
        case .failure: succeeded = false
        }
        #expect(succeeded)
        let requests = await server.log.requests
        #expect(requests.map(\.path) == ["/posts.echo", "/posts.echo", "/auth.refresh", "/posts.echo"])
        let retriedWithNewLogin = requests.last?.headers["authorization"] == "Bearer " + newLogin.accessToken
        #expect(retriedWithNewLogin)
        let saved = try #require(await store.load())
        let newLoginPreserved = sameRecord(saved, newLogin)
        #expect(newLoginPreserved)
    }
}

@Test func testSuccessfulRefreshDoesNotOverwriteNewLogin() async throws {
    let gate = PeerGate()
    let refreshed = try wire(record("https://example.com"))
    try await withPeer([.reply(401, unauthorized), .gatedReply(200, refreshed, gate),
                        .reply(200, validBody)]) { server in
        let store = try MemorySessionStore(origin: server.origin)
        try await store.save(record(server.origin))
        let transport = try ClientTransport(origin: server.origin).withSession(store)
        let call = Task { try await transport.invoke("notes.write", input: Empty(), as: Payload.self) }
        await server.log.waitForRequests(2)
        let newLogin = try record(server.origin)
        try await store.save(newLogin)
        let installed = try await store.load()
        let newLoginInstalled = installed?.credential == newLogin.credential
        await gate.open()
        #expect(newLoginInstalled)
        #expect(try await call.value.value == "ok")
        let saved = try #require(await store.load())
        let newLoginPreserved = sameRecord(saved, newLogin)
        #expect(newLoginPreserved)
        let requests = await server.log.requests
        #expect(requests.map(\.path) == ["/notes.write", "/auth.refresh", "/notes.write"])
        let retriedWithNewLogin = requests.last?.headers["authorization"] == "Bearer " + newLogin.accessToken
        #expect(retriedWithNewLogin)
    }
}

@Test func testUncertainRefreshKeepsStoredCredential() async throws {
    try await withPeer([.reply(401, unauthorized), .disconnect]) { server in
        let store = try MemorySessionStore(origin: server.origin)
        let original = try record(server.origin)
        try await store.save(original)
        let transport = try ClientTransport(origin: server.origin).withSession(store)
        await expectFailure("transport_error", status: nil) {
            let _: Payload = try await transport.invoke("notes.write", input: Empty())
        }
        let saved = try #require(await store.load())
        let originalPreserved = sameRecord(saved, original)
        #expect(originalPreserved)
        #expect(await server.log.requests.map(\.path) == ["/notes.write", "/auth.refresh"])
    }
}

@Test func testRefreshMissingRequiredFieldsIsRejected() async throws {
    let complete = try JSONDecoder().decode([String: String].self, from: wire(record("https://example.com")))
    for field in complete.keys.sorted() {
        var incomplete = complete
        incomplete[field] = nil
        try await withPeer([.reply(401, unauthorized), .reply(200, try JSONEncoder().encode(incomplete))]) { server in
            let store = try MemorySessionStore(origin: server.origin)
            let original = try record(server.origin)
            try await store.save(original)
            let transport = try ClientTransport(origin: server.origin).withSession(store)
            await expectFailure("invalid_response", status: 200) {
                let _: Payload = try await transport.invoke("notes.write", input: Empty())
            }
            let saved = try #require(await store.load())
            let originalPreserved = sameRecord(saved, original)
            #expect(originalPreserved)
            #expect(await server.log.requests.map(\.path) == ["/notes.write", "/auth.refresh"])
        }
    }
}

private actor FailingStore: SessionStore {
    nonisolated let origin: String
    nonisolated let coordinator = SessionCoordinator()
    private let record: SessionRecord?
    private let failure: String
    init(origin: String, record: SessionRecord?, failure: String) {
        self.origin = origin; self.record = record; self.failure = failure
    }
    func load() async throws -> SessionRecord? {
        if failure == "load" { throw CocoaError(.fileReadNoPermission) }
        return record
    }
    func save(_ session: SessionRecord) async throws { throw CocoaError(.fileWriteNoPermission) }
    func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool {
        throw CocoaError(.fileWriteNoPermission)
    }
    func clear(ifMatching expected: SessionRecord) async throws -> Bool { throw CocoaError(.fileWriteNoPermission) }
}

@Test func testSessionStoreFailureIsNotAnonymous() async throws {
    for stage in ["load", "replace", "clear"] {
        let refreshed = try wire(record("https://example.com"))
        try await withPeer([.reply(401, unauthorized), stage == "clear" ? .reply(401, unauthorized) : .reply(200, refreshed),
                            .reply(401, unauthorized)]) { server in
            let store = FailingStore(origin: server.origin, record: try record(server.origin), failure: stage)
            let transport = try ClientTransport(origin: server.origin).withSession(store)
            await expectFailure("session_store_error", status: nil) {
                let _: Payload = try await transport.invoke("notes.write", input: Empty())
            }
            if stage == "load" { #expect(await server.log.requests.isEmpty) }
            else {
                await expectFailure("invalid_token", status: 401) {
                    let _: Payload = try await transport.invoke("notes.write", input: Empty())
                }
                #expect(await server.log.requests.filter { $0.path == "/auth.refresh" }.count == 1)
            }
        }
    }
}

@Test func sessionRefreshConditionsPreserveCodeAndStatus() async throws {
    for (status, code, operation) in [(403, "invalid_token", "notes.write"), (401, "denied", "notes.write"),
                                    (401, "invalid_token", "auth.refresh")] {
        try await withPeer([.reply(status, try JSONEncoder().encode(["error": code]))]) { server in
            let store = try MemorySessionStore(origin: server.origin)
            try await store.save(record(server.origin))
            let transport = try ClientTransport(origin: server.origin).withSession(store)
            await expectFailure(code, status: status) {
                let _: Payload = try await transport.invoke(operation, input: Empty())
            }
            #expect(await server.log.requests.count == 1)
        }
    }
}

@Test func sessionOriginCopiesAndRedaction() async throws {
    try await withPeer(Array(repeating: .reply(200, validBody), count: 3)) { server in
        let store = try MemorySessionStore(origin: server.origin)
        let session = try record(server.origin)
        try await store.save(session)
        let anonymous = try ClientTransport(origin: server.origin)
        let authenticated = try anonymous.withSession(store)
        let explicit = try authenticated.withBearer(randomToken())
        for transport in [anonymous, authenticated, explicit] {
            let _: Payload = try await transport.invoke("notes.read", input: Empty())
        }
        let requests = await server.log.requests
        #expect(requests[0].headers["authorization"] == nil)
        let storedBearer = requests[1].headers["authorization"] == "Bearer " + session.accessToken
        #expect(storedBearer)
        #expect(requests[2].headers["authorization"] != nil)
        let other = try MemorySessionStore(origin: "https://example.com")
        #expect(throws: OperationError.self) { try anonymous.withSession(other) }
        await #expect(throws: OperationError.self) { try await other.save(session) }
        let wrongOrigin = FailingStore(origin: server.origin, record: try record("https://example.com"), failure: "none")
        let mismatched = try anonymous.withSession(wrongOrigin)
        await expectFailure("session_store_error", status: nil) {
            let _: Payload = try await mismatched.invoke("notes.read", input: Empty())
        }
        #expect(await server.log.requests.count == 3)
        for value: any CustomReflectable in [session, store, store.coordinator, authenticated] {
            var output = ""
            dump(value, to: &output)
            let redacted = !output.contains(session.accessToken) && !output.contains(session.refreshToken)
            #expect(redacted)
        }
    }
}

@Test func cancelledRefreshWaiterLeavesOtherWaitersRunning() async throws {
    let gate = PeerGate()
    let refreshed = try wire(record("https://example.com"))
    let server = try LoopbackServer(responder: { request in
        request.path == "/auth.refresh" ? .gatedReply(200, refreshed, gate) : .reply(401, unauthorized)
    })
    let store = try MemorySessionStore(origin: server.origin)
    try await store.save(record(server.origin))
    let transport = try ClientTransport(origin: server.origin).withSession(store)
    let first = Task { try await transport.invoke("notes.write", input: Empty(), as: Payload.self) }
    let second = Task { try await transport.invoke("notes.write", input: Empty(), as: Payload.self) }
    let joined = await waitForFlight(store.coordinator, count: 2, server: server)
    #expect(joined)
    first.cancel()
    await expectFailure("cancelled", status: nil) { _ = try await first.value }
    await gate.open()
    await expectFailure("invalid_token", status: 401) { _ = try await second.value }
    #expect(await server.log.requests.filter { $0.path == "/auth.refresh" }.count == 1)
    #expect(await server.log.requests.filter { $0.path == "/notes.write" }.count == 3)
    await server.stop()
}

private actor WaitingStore: SessionStore {
    nonisolated let origin: String
    nonisolated let coordinator = SessionCoordinator()
    let gate: PeerGate
    let entered = PeerGate()
    init(origin: String, gate: PeerGate) { self.origin = origin; self.gate = gate }
    func load() async throws -> SessionRecord? {
        await entered.open()
        await gate.wait()
        return nil
    }
    func save(_ session: SessionRecord) async throws {}
    func replace(_ session: SessionRecord, ifMatching expected: SessionRecord) async throws -> Bool { false }
    func clear(ifMatching expected: SessionRecord) async throws -> Bool { false }
}

@Test func sessionStorageWaitHonorsDeadlineAndCancellation() async throws {
    try await withPeer { server in
        for cancel in [false, true] {
            let gate = PeerGate()
            let store = WaitingStore(origin: server.origin, gate: gate)
            let transport = try ClientTransport(origin: server.origin, timeout: 30).withSession(store)
            let call = Task { try await transport.invoke("notes.write", input: Empty(), as: Payload.self) }
            await store.entered.wait()
            if cancel { call.cancel() }
            await expectFailure(cancel ? "cancelled" : "timeout", status: nil) { _ = try await call.value }
            await gate.open()
        }
        #expect(await server.log.requests.isEmpty)
    }
}

@Test func lastCancelledWaiterDoesNotReuseRefresh() async throws {
    try await withPeer([.reply(401, unauthorized), .stall(false), .reply(401, unauthorized)]) { server in
        let store = try MemorySessionStore(origin: server.origin)
        try await store.save(record(server.origin))
        let transport = try ClientTransport(origin: server.origin).withSession(store)
        let call = Task { try await transport.invoke("notes.write", input: Empty(), as: Payload.self) }
        await server.log.waitForRequests(2)
        call.cancel()
        await expectFailure("cancelled", status: nil) { _ = try await call.value }
        await expectFailure("invalid_token", status: 401) {
            let _: Payload = try await transport.invoke("notes.write", input: Empty())
        }
        await server.log.waitForCompletions(3)
        #expect(await server.log.requests.filter { $0.path == "/auth.refresh" }.count == 1)
        #expect(await server.log.completions.contains { $0.disconnected })
    }
}

private struct SlowDecodedOutput: Decodable, Sendable {
    static let entered = PeerGate()
    init(from decoder: any Decoder) throws {
        _ = try decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .value)
        Task { await Self.entered.open() }
        Thread.sleep(forTimeInterval: 31)
    }
    private enum CodingKeys: String, CodingKey { case value }
}

@Test func callDeadlineIncludesResponseDecoding() async throws {
    try await withPeer([.reply(200, validBody)]) { server in
        let transport = try ClientTransport(origin: server.origin, timeout: 30)
        let call = Task { try await transport.invoke("notes.read", input: Empty(), as: SlowDecodedOutput.self) }
        await SlowDecodedOutput.entered.wait()
        await expectFailure("timeout", status: 200) { _ = try await call.value }
        #expect(await server.log.requests.count == 1)
    }
}
