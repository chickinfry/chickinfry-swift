import Foundation
import Testing
@testable import SwiftSDKDriver
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [JSON] = []
    func append(_ value: JSON) { lock.withLock { storage.append(value) } }
    var values: [JSON] { lock.withLock { storage } }
    func wait(_ predicate: (JSON) -> Bool) async throws -> JSON {
        let end = DispatchTime.now().uptimeNanoseconds + 5_000_000_000
        while DispatchTime.now().uptimeNanoseconds < end {
            if let value = values.first(where: predicate) { return value }
            await Task.yield()
        }
        throw ProtocolFailure.deadline
    }
}

private func request(_ id: String, _ command: String, _ args: [String: JSON]) -> JSON {
    .object(["id": .string(id), "command": .string(command), "args": .object(args)])
}

private func handshake(_ driver: Driver) async throws {
    try await driver.receive(request("c:hello", "handshake", [
        "protocolVersions": .array([.int(1)]), "runId": .string("run"), "requiredCapabilities": .array([]),
        "target": .object(["language": .string("swift"), "role": .string("sdk"), "environment": .string("native")]),
    ]))
}

@Test func framingRejectsTruncationAndOversizedLines() throws {
    var frame = Framer(limit: 4)
    #expect(try frame.append(Data("abc".utf8)).isEmpty)
    #expect(throws: ProtocolFailure.self) { try frame.end() }
    #expect(try frame.append(Data([10])) == [Data("abc".utf8)])
    try frame.end()
    #expect(throws: ProtocolFailure.self) { try frame.append(Data("abcde".utf8)) }
    var control = Framer(limit: 16 * 1024 * 1024)
    #expect(try control.append(Data([10, 10])).count == 2)
}

private func writeOversizedLine(_ value: JSON, limit: Int, to handle: FileHandle) throws {
    let prefix = try JSONEncoder().encode(value)
    try handle.write(contentsOf: prefix)
    let chunk = Data(repeating: 32, count: 16 * 1024)
    var remaining = limit - prefix.count
    while remaining > 0 {
        let count = min(remaining, chunk.count)
        try handle.write(contentsOf: chunk.prefix(count))
        remaining -= count
    }
    try handle.write(contentsOf: Data([10]))
}

@Test func executableDoesNotInheritUnrelatedPipeEnds() throws {
    let unrelated = Pipe()
    defer {
        try? unrelated.fileHandleForReading.close()
        try? unrelated.fileHandleForWriting.close()
    }
    // Force another test's pipe-creation/spawn interleaving before its CLOEXEC setup.
    let process = try DriverProcess()
    try unrelated.fileHandleForWriting.close()
    var ready = pollfd(fd: unrelated.fileHandleForReading.fileDescriptor,
                       events: Int16(POLLIN | POLLHUP), revents: 0)
    #expect(poll(&ready, 1, 300) == 1)
    #expect(ready.revents & Int16(POLLHUP) != 0)
    #expect(try process.finish().status == 0)
}

@Test func controlLineOver16MiBIsRejected() throws {
    let process = try DriverProcess()
    try process.protected.close()
    let hello = request("c:hello", "handshake", [
        "protocolVersions": .array([.int(1)]), "runId": .string("run"), "requiredCapabilities": .array([]),
        "target": .object(["language": .string("swift"), "role": .string("sdk"), "environment": .string("native")]),
    ])
    try writeOversizedLine(hello, limit: 16 * 1024 * 1024, to: process.input)
    let finished = try process.finish()
    #expect(finished.status == 256)
    #expect(finished.messages.isEmpty)
}

@Test func protectedLineOver64KiBIsRejected() throws {
    let process = try DriverProcess()
    let hello = request("c:hello", "handshake", [
        "protocolVersions": .array([.int(1)]), "runId": .string("run"), "requiredCapabilities": .array([]),
        "target": .object(["language": .string("swift"), "role": .string("sdk"), "environment": .string("native")]),
    ])
    try process.send(hello)
    try writeOversizedLine(.object(["ref": .string("opaque"), "value": .string(UUID().uuidString)]),
                           limit: 64 * 1024, to: process.protected)
    let finished = try process.finish()
    #expect(finished.status == 256)
    #expect(finished.messages.isEmpty)
}

@Test func duplicateKeysAreRejectedBeforeDecoding() throws {
    for source in [#"{"id":1,"id":2}"#, #"{"args":{"x":1,"\u0078":2}}"#, #"{"a":[{"x":0,"x":1}]}"#,
                   #"{"a":1} {}"#, #"{"a":01}"#] {
        #expect(throws: ProtocolFailure.self) {
            var parser = try JSONParser(Data(source.utf8))
            _ = try parser.parse()
        }
    }
    var parser = try JSONParser(Data(#"{"a":[null,true,false,-1,1.5,"a\"b"]}"#.utf8))
    #expect(try parser.parse()["a"].array?.count == 6)
}

@Test func duplicateAndUnknownMessageIDsAreRejected() async throws {
    let messages = Messages()
    let driver = Driver(credentials: [:], output: { messages.append($0) })
    try await handshake(driver)
    await #expect(throws: ProtocolFailure.self) { try await handshake(driver) }
    await #expect(throws: ProtocolFailure.self) {
        try await driver.receive(.object(["id": .string("d:missing"), "result": .object([:]), "error": .null]))
    }
    await driver.shutdown()
}

@Test func unknownCommandFieldsAreRejected() async throws {
    let messages = Messages()
    let driver = Driver(credentials: [:], output: { messages.append($0) })
    try await handshake(driver)
    var command = try #require(request("c:unknown", "session.store.create", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "storeRef": .string("store"),
        "origin": .string("http://127.0.0.1"),
    ]).object)
    command["unknown"] = .bool(true)
    do {
        try await driver.receive(.object(command))
        Issue.record("Expected protocol_violation for an unknown command field")
    } catch ProtocolFailure.violation {}
    try await driver.receive(request("c:args", "session.store.create", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "storeRef": .string("store"),
        "origin": .string("http://127.0.0.1"), "unknown": .bool(true),
    ]))
    let rejected = try await messages.wait { $0["id"] == .string("c:args") }
    #expect(rejected["error"]["code"] == .string("protocol_violation"))
    await driver.shutdown()
}

@Test func executableCancelsPendingBarrierOnEOF() throws {
    let process = try DriverProcess()
    try process.protected.close()
    try executableHandshake(process)
    let common: [String: JSON] = ["caseId": .string("case"), "timeoutMs": .int(30000)]
    try process.send(request("c:create", "client.create", common.merging([
        "clientRef": .string("client"), "fixture": .string("plain"), "origin": .string("http://127.0.0.1:1"),
        "requestTimeoutMs": .int(30000),
    ]) { _, new in new }))
    let created = try #require(try process.readMessage())
    #expect(created["error"] == .null)
    try process.send(request("c:arm", "barrier.arm", common.merging([
        "barrierRef": .string("entry"), "point": .string("sdk-entered"), "participants": .array([.string("c:blocked")]),
    ]) { _, new in new }))
    let armed = try #require(try process.readMessage())
    #expect(armed["result"]["state"] == .string("armed"))
    try process.send(request("c:blocked", "client.call", common.merging([
        "clientRef": .string("client"), "operation": .string("probe.echo"),
        "input": .object(["wire_value": .string("test")]),
    ]) { _, new in new }))
    let arrived = try #require(try process.readMessage())
    #expect(arrived["command"] == .string("barrier.arrive"))
    #expect(arrived["args"]["callId"] == .string("c:blocked"))
    let finished = try process.finish()
    #expect(finished.status == 0)
    #expect(finished.messages.count == 1)
    #expect(finished.messages.first?["id"] == .string("c:blocked"))
    #expect(finished.messages.first?["error"]["code"] == .string("driver_failed"))
}

@Test(arguments: [false, true]) func pendingTasksAreReapedOnEOFAndDeadline(deadline: Bool) async throws {
    let messages = Messages()
    let driver = Driver(credentials: [:], output: { messages.append($0) })
    try await handshake(driver)
    let common: [String: JSON] = ["caseId": .string("case"), "timeoutMs": .int(5000)]
    try await driver.receive(request("c:create", "client.create", common.merging([
        "clientRef": .string("client"), "fixture": .string("plain"), "origin": .string("http://127.0.0.1:1"),
        "requestTimeoutMs": .int(1000),
    ]) { _, new in new }))
    _ = try await messages.wait { $0["id"] == .string("c:create") }
    try await driver.receive(request("c:arm", "barrier.arm", common.merging([
        "barrierRef": .string("entry"), "point": .string("sdk-entered"), "participants": .array([.string("c:blocked")]),
    ]) { _, new in new }))
    _ = try await messages.wait { $0["id"] == .string("c:arm") }
    try await driver.receive(request("c:blocked", "client.call", [
        "caseId": .string("case"), "timeoutMs": .int(deadline ? 100 : 5000), "clientRef": .string("client"),
        "operation": .string("probe.echo"), "input": .object(["wire_value": .string("test")]),
    ]))
    _ = try await messages.wait { $0["command"] == .string("barrier.arrive") }
    if deadline {
        let result = try await messages.wait { $0["id"] == .string("c:blocked") }
        #expect(result["error"]["code"] == .string("deadline_exceeded"))
    }
    await driver.shutdown()
    #expect(await driver.activeTaskCount == 0)
}

private func inheritedSession() throws -> [String: String] {
    let access = randomSessionToken(), refresh = randomSessionToken()
    let record = try JSONEncoder().encode([
        "origin": "http://127.0.0.1", "access_token": access, "refresh_token": refresh,
        "expires_at": "original", "refresh_expires_at": "original", "user_id": "user", "session_id": "session",
    ])
    return ["access": access, "refresh": refresh, "record": String(decoding: record, as: UTF8.self)]
}

private func executableHandshake(_ process: DriverProcess) throws {
    try process.send(request("c:hello", "handshake", [
        "protocolVersions": .array([.int(1)]), "runId": .string("run"), "requiredCapabilities": .array([]),
        "target": .object(["language": .string("swift"), "role": .string("sdk"), "environment": .string("native")]),
    ]))
    let hello = try #require(try process.readMessage())
    #expect(hello["result"]["protocolVersion"] == .int(1))
}

private func createInheritedStore(_ process: DriverProcess) throws -> JSON {
    try process.send(request("c:store", "session.store.create", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "storeRef": .string("store"),
        "origin": .string("http://127.0.0.1"), "recordRef": .string("record"),
        "accessRef": .string("access"), "refreshRef": .string("refresh"),
    ]))
    return try #require(try process.readMessage())
}

@Test func credentialsAreReadFromTheInheritedPipeUntilEOF() throws {
    let process = try DriverProcess()
    let values = try inheritedSession()
    try process.sendCredentials(["access": values["access"]!])
    try process.sendCredentials(values.filter { $0.key != "access" })
    try process.protected.close()
    try executableHandshake(process)
    let stored = try createInheritedStore(process)
    #expect(stored["id"] == .string("c:store"))
    #expect(stored["error"] == .null)
    #expect(stored["result"]["revision"] == .int(1))
    try process.send(request("c:read", "session.store.read", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "storeRef": .string("store"), "includeTrace": .bool(false),
    ]))
    let read = try #require(try process.readMessage())
    #expect(read["result"]["present"] == .bool(true))
    #expect(read["result"]["accessRef"] == .string("access"))
    #expect(read["result"]["refreshRef"] == .string("refresh"))
    let text = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
    let stayedPrivate = !values.values.contains { text.contains($0) }
    #expect(stayedPrivate)
    let finished = try process.finish()
    #expect(finished.status == 0)
    #expect(finished.messages.isEmpty)
}

@Test func executableConsumesCredentialsOnlyFromFD3() throws {
    let process = try DriverProcess(environment: inheritedSession())
    try process.protected.close()
    try executableHandshake(process)
    let stored = try createInheritedStore(process)
    #expect(stored["error"]["code"] == .string("invalid_reference"))
    let finished = try process.finish()
    #expect(finished.status == 0)
    #expect(finished.messages.isEmpty)
}

@Test func protectedFramingRejectsDuplicateReferencesAndUnknownFields() throws {
    for message in [
        JSON.object(["ref": .string("item"), "value": .string(UUID().uuidString), "extra": .bool(true)]),
        JSON.object(["ref": .string("item"), "value": .string(UUID().uuidString)]),
    ] {
        var descriptors: [Int32] = [0, 0]
        #expect(pipe(&descriptors) == 0)
        var bytes = try JSONEncoder().encode(message) + Data([10])
        if message.object?["extra"] == nil { bytes += bytes }
        _ = bytes.withUnsafeBytes { write(descriptors[1], $0.baseAddress, $0.count) }
        close(descriptors[1])
        #expect(throws: ProtocolFailure.self) { try loadCredentials(descriptor: descriptors[0]) }
    }
}

@Test func transportObservationRejectsUnknownCalls() async throws {
    let messages = Messages()
    let driver = Driver(credentials: [:], output: { messages.append($0) })
    try await handshake(driver)
    try await driver.receive(request("c:observe", "client.observe", [
        "caseId": .string("case"), "timeoutMs": .int(1000), "callId": .string("c:missing"), "afterSequence": .int(0),
    ]))
    let result = try await messages.wait { $0["id"] == .string("c:observe") }
    #expect(result["error"]["code"] == .string("invalid_reference"))
    await driver.shutdown()
}

@Test func aRegisteredCallCanBeObservedBeforeSDKEntry() throws {
    let observation = TransportObservation()
    observation.register("c:pending")
    let result = try observation.snapshot("c:pending", after: 0)
    #expect(result["complete"] == .bool(true))
    #expect(result["events"] == .array([]))
}

@Test func newlyReturnedCredentialsRemainPrivateWithoutOutputReferences() async throws {
    let access = UUID().uuidString + UUID().uuidString
    let refresh = UUID().uuidString + UUID().uuidString
    let exposedCode = String((0..<43).map { _ in Character(UnicodeScalar(Int.random(in: 97...122))!) })
    let password = UUID().uuidString + UUID().uuidString
    let login = try JSONEncoder().encode([
        "access_token": access, "refresh_token": refresh, "expires_at": "2026-10-15T01:02:03Z",
        "refresh_expires_at": "2026-11-15T01:02:03Z", "user_id": UUID().uuidString, "session_id": UUID().uuidString,
    ])
    let echo = try JSONEncoder().encode(["wire_value": access + refresh, "observed_at": "2026-10-15T01:02:03Z"])
    let rejection = try JSONEncoder().encode(["error": exposedCode])
    let peer = try TestPeer(responses: [(200, login), (200, echo), (400, rejection)], chunkSize: 4096)
    let origin = try await peer.start()
    defer { peer.stop() }
    let messages = Messages()
    let driver = Driver(credentials: ["password": password, "code": exposedCode], output: { messages.append($0) })
    try await handshake(driver)
    try await driver.receive(request("c:create", "client.create", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "clientRef": .string("client"), "fixture": .string("auth"),
        "origin": .string(origin), "requestTimeoutMs": .int(1000),
    ]))
    _ = try await messages.wait { $0["id"] == .string("c:create") }
    try await driver.receive(request("c:login", "client.call", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "clientRef": .string("client"), "operation": .string("auth.signin"),
        "input": .object(["email": .string("reader@example.test")]), "inputRefs": .object(["password": .string("password")]),
    ]))
    let signedIn = try await messages.wait { $0["id"] == .string("c:login") }
    #expect(signedIn["error"] == .null)
    try await driver.receive(request("c:echo", "client.call", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "clientRef": .string("client"), "operation": .string("probe.echo"),
        "input": .object(["wire_value": .string("safe")]),
    ]))
    let echoed = try await messages.wait { $0["id"] == .string("c:echo") }
    #expect(echoed["result"]["output"]["wire_value"] == .null)
    try await driver.receive(request("c:rejection", "client.call", [
        "caseId": .string("case"), "timeoutMs": .int(5000), "clientRef": .string("client"), "operation": .string("probe.echo"),
        "input": .object(["wire_value": .string("safe")]),
    ]))
    let rejected = try await messages.wait { $0["id"] == .string("c:rejection") }
    #expect(rejected["error"]["code"] == .null)
    #expect(rejected["error"]["rawTransportDetails"] == .bool(true))
    let encoded = try JSONEncoder().encode(JSON.array(messages.values))
    let text = String(decoding: encoded, as: UTF8.self)
    let stayedPrivate = ![access, refresh, exposedCode, password].contains { text.contains($0) }
    #expect(stayedPrivate)
    await driver.shutdown()
}

private func randomSessionToken() -> String {
    String((UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").prefix(43))
}

@Test func automaticRefreshCredentialsRemainPrivateWithoutOutputReferences() async throws {
    let oldAccess = randomSessionToken()
    let oldRefresh = randomSessionToken()
    let access = randomSessionToken()
    let refresh = randomSessionToken()
    let refreshed = try JSONEncoder().encode([
        "access_token": access, "refresh_token": refresh, "expires_at": "later",
        "refresh_expires_at": "latest", "user_id": UUID().uuidString, "session_id": UUID().uuidString,
    ])
    let echo = try JSONEncoder().encode(["wire_value": access + refresh, "observed_at": "now"])
    let rejection = try JSONEncoder().encode(["error": "invalid_token"])
    let peer = try TestPeer(responses: [(401, rejection), (200, refreshed), (200, echo)], chunkSize: 4096)
    let origin = try await peer.start()
    defer { peer.stop() }
    let original = try JSONEncoder().encode([
        "origin": origin, "access_token": oldAccess, "refresh_token": oldRefresh,
        "expires_at": "before", "refresh_expires_at": "later", "user_id": UUID().uuidString,
        "session_id": UUID().uuidString,
    ])
    let messages = Messages()
    let driver = Driver(credentials: ["old-access": oldAccess, "old-refresh": oldRefresh,
                                      "original": String(decoding: original, as: UTF8.self)],
                        output: { messages.append($0) })
    try await handshake(driver)
    let common: [String: JSON] = ["caseId": .string("private-refresh"), "timeoutMs": .int(5000)]
    try await driver.receive(request("c:store", "session.store.create", common.merging([
        "storeRef": .string("shared"), "origin": .string(origin), "recordRef": .string("original"),
        "accessRef": .string("old-access"), "refreshRef": .string("old-refresh"),
    ]) { _, new in new }))
    let stored = try await messages.wait { $0["id"] == .string("c:store") }
    #expect(stored["error"] == .null)
    try await driver.receive(request("c:create", "client.create", common.merging([
        "clientRef": .string("auth"), "fixture": .string("auth"), "origin": .string(origin),
        "requestTimeoutMs": .int(3000), "storeRef": .string("shared"),
    ]) { _, new in new }))
    let created = try await messages.wait { $0["id"] == .string("c:create") }
    #expect(created["error"] == .null)
    try await driver.receive(request("c:echo", "client.call", common.merging([
        "clientRef": .string("auth"), "operation": .string("probe.echo"),
        "input": .object(["wire_value": .string("hello")]),
    ]) { _, new in new }))
    let echoed = try await messages.wait { $0["id"] == .string("c:echo") }
    #expect(echoed["error"] == .null)
    let ordinaryOutputRedacted = echoed["result"]["output"]["wire_value"] == .null
    #expect(ordinaryOutputRedacted)
    #expect(peer.connectionCount == 3)
    let encoded = try JSONEncoder().encode(JSON.array(messages.values))
    let text = String(decoding: encoded, as: UTF8.self)
    let stayedPrivate = ![oldAccess, oldRefresh, access, refresh].contains { text.contains($0) }
    #expect(stayedPrivate)
    await driver.shutdown()
}

@Test func sdkDeadlineIncludesTimeAtTheEntryBarrier() async throws {
    let body = try JSONEncoder().encode(["wire_value": "safe", "observed_at": "2026-10-15T01:02:03Z"])
    let peer = try TestPeer(body: body, chunkSize: 4096)
    let origin = try await peer.start()
    defer { peer.stop() }
    let messages = Messages()
    let driver = Driver(credentials: [:], output: { messages.append($0) })
    try await handshake(driver)
    let common: [String: JSON] = ["caseId": .string("case"), "timeoutMs": .int(5000)]
    try await driver.receive(request("c:create", "client.create", common.merging([
        "clientRef": .string("client"), "fixture": .string("plain"), "origin": .string(origin), "requestTimeoutMs": .int(100),
    ]) { _, new in new }))
    _ = try await messages.wait { $0["id"] == .string("c:create") }
    try await driver.receive(request("c:arm", "barrier.arm", common.merging([
        "barrierRef": .string("entry"), "point": .string("sdk-entered"), "participants": .array([.string("c:call")]),
    ]) { _, new in new }))
    _ = try await messages.wait { $0["id"] == .string("c:arm") }
    try await driver.receive(request("c:call", "client.call", common.merging([
        "clientRef": .string("client"), "operation": .string("probe.echo"), "input": .object(["wire_value": .string("safe")]),
    ]) { _, new in new }))
    let arrival = try await messages.wait { $0["command"] == .string("barrier.arrive") }
    // Keep the actual barrier held until the SDK's own deadline has elapsed.
    try await Task.sleep(nanoseconds: 150_000_000)
    try await driver.receive(.object(["id": arrival["id"], "result": .object([
        "barrierRef": .string("entry"), "state": .string("released"), "sequence": .int(1),
    ]), "error": .null]))
    let result = try await messages.wait { $0["id"] == .string("c:call") }
    #expect(result["error"]["kind"] == .string("sdk"))
    #expect(result["error"]["code"] == .string("timeout"))
    #expect(result["error"]["outcomeUnknown"] == .bool(false))
    #expect(peer.connectionCount == 0)
    await driver.shutdown()
}
