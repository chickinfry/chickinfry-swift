import Foundation
import Testing
@testable import Chickinfry

private struct Payload: Codable, Sendable { let value: String }
private struct Empty: Codable, Sendable {}
private let validBody = Data("{\"value\":\"ok\"}".utf8)

private func withPeer(_ responses: [PeerResponse] = [],
                      body: @Sendable (LoopbackServer) async throws -> Void) async throws {
    let server = try LoopbackServer(responses)
    do {
        try await body(server)
        await server.stop()
    } catch {
        await server.stop()
        throw error
    }
}

@discardableResult
private func expectFailure(_ code: String, status: Int?,
                           body: @Sendable () async throws -> Void) async -> OperationError? {
    do {
        try await body()
        Issue.record("Expected an operation failure")
        return nil
    } catch let error as OperationError {
        #expect(error.code == code)
        #expect(error.status == status)
        return error
    } catch {
        Issue.record("Expected a safe OperationError, received \(type(of: error))")
        return nil
    }
}

@Test func wireAndImmutableBearerCopies() async throws {
    let token = String(repeating: "a", count: 43)
    let otherToken = String(repeating: "b", count: 43)
    let value = "2026-10-14T01:02:03.123456789Z / 한글 \"value\""
    let data = try JSONEncoder().encode(Payload(value: value))
    try await withPeer(Array(repeating: .reply(200, data), count: 3)) { server in
        let original = try ClientTransport(origin: server.origin + "/")
        let authenticated = try original.withBearer(token)
        let other = try authenticated.withBearer(otherToken)
        async let first: Payload = original.invoke("notes.create_note", input: Payload(value: value))
        async let second: Payload = authenticated.invoke("notes.create_note", input: Payload(value: value))
        async let third: Payload = other.invoke("notes.create_note", input: Payload(value: value))
        let results = try await [first, second, third]
        #expect(results.allSatisfy { $0.value == value })
        await server.log.waitForCompletions(3)
        let requests = await server.log.requests
        #expect(requests.count == 3)
        #expect(requests.allSatisfy { $0.method == "POST" && $0.path == "/notes.create_note" })
        #expect(requests.allSatisfy { $0.headers["content-type"] == "application/json" })
        #expect(requests.filter { $0.headers["authorization"] == nil }.count == 1)
        #expect(requests.filter { $0.headers["authorization"] == "Bearer " + token }.count == 1)
        #expect(requests.filter { $0.headers["authorization"] == "Bearer " + otherToken }.count == 1)
        for request in requests {
            #expect(try JSONDecoder().decode(Payload.self, from: request.body).value == value)
        }
        for malformed in ["", "short", token + "\r\nInjected: secret", String(repeating: "/", count: 43)] {
            #expect(throws: OperationError.self) { try original.withBearer(malformed) }
        }
    }
}

@Test func transportFormattingDoesNotExposeCredentials() throws {
    let token = String((UUID().uuidString + UUID().uuidString).filter { $0 != "-" }.prefix(43))
    let transport = try ClientTransport(origin: "https://example.com").withBearer(token)
    var printed = ""
    print(transport, to: &printed)
    var dumped = ""
    dump(transport, to: &dumped)
    for (path, output) in [("describing", String(describing: transport)),
                           ("reflecting", String(reflecting: transport)),
                           ("print", printed), ("dump", dumped)] {
        let redacted = !output.contains(token)
        #expect(redacted, "Credentials must be excluded from \(path) output")
    }
}

@Test func rawOriginsAreRejectedBeforeNetwork() async throws {
    for accepted in ["https://example.com", "https://example.com:443/", "http://127.0.0.1",
                     "http://127.255.0.254:8080/", "http://[::1]", "http://[::1]:8080/"] {
        #expect(throws: Never.self) { try ClientTransport(origin: accepted) }
    }
    try await withPeer([.reply(200, validBody)]) { server in
        let rejected = [
            server.origin + "?", server.origin + "#", server.origin + "?a=b", server.origin + "#part",
            server.origin + "/path", server.origin + "//", server.origin + "/./", " " + server.origin,
            server.origin.replacingOccurrences(of: "://", with: "://user@"),
            server.origin.replacingOccurrences(of: "://", with: "://user:password@"),
            "http://localhost", "http://192.168.1.1", "http://example.com", "ftp://127.0.0.1",
            "http://127.1", "http://127.0.1", "http://2130706433", "http://0x7f000001",
            "http://0177.0.0.1", "http://127.00.0.1", "http://127.0.0.256", "http://[::ffff:127.0.0.1]",
            "http://[0:0:0:0:0:0:0:1]", "http://%31%32%37.0.0.1", "http://127.0.0.1:",
            "http://127.0.0.1:0", "http://127.0.0.1:65536", "http://127.0.0.1\\@example.com",
            "", "https:///", "https://example.com\n",
        ]
        for origin in rejected {
            await expectFailure("invalid_origin", status: nil) {
                let transport = try ClientTransport(origin: origin)
                let _: Payload = try await transport.invoke("notes.read", input: Empty())
            }
        }
        #expect(await server.log.requests.count == 0)
        let transport = try ClientTransport(origin: server.origin)
        for operation in ["notes.read\n", "notes/read", "../notes.read", "notes.read?query"] {
            await expectFailure("invalid_input", status: nil) {
                let _: Payload = try await transport.invoke(operation, input: Empty())
            }
        }
        for timeout in [0, -1, .infinity, .nan] as [TimeInterval] {
            #expect(throws: OperationError.self) { try ClientTransport(origin: server.origin, timeout: timeout) }
        }
        #expect(await server.log.requests.count == 0)
        let _: Payload = try await transport.invoke("notes.read", input: Empty())
        #expect(await server.log.requests.count == 1)
    }
}

@Test func actualSerializedRequestLimit() async throws {
    let overhead = try JSONEncoder().encode(Payload(value: "")).count
    let boundary = Payload(value: String(repeating: "x", count: 4 * 1024 * 1024 - overhead))
    #expect(try JSONEncoder().encode(boundary).count == 4 * 1024 * 1024)
    try await withPeer([.reply(200, validBody)]) { server in
        let transport = try ClientTransport(origin: server.origin)
        let _: Payload = try await transport.invoke("notes.write", input: boundary)
        await server.log.waitForCompletions(1)
        #expect(await server.log.requests.first?.body.count == 4 * 1024 * 1024)
        for oversized in [Payload(value: boundary.value + "x"),
                          Payload(value: String(repeating: "é", count: 2 * 1024 * 1024))] {
            await expectFailure("request_too_large", status: nil) {
                let _: Payload = try await transport.invoke("notes.write", input: oversized)
            }
        }
        #expect(await server.log.requests.count == 1)
    }
}

@Test func responseBoundaryAndCancellationDuringUnknownLengthStream() async throws {
    let overhead = try JSONEncoder().encode(Payload(value: "")).count
    let payload = Payload(value: String(repeating: "x", count: 1024 * 1024 - overhead))
    let data = try JSONEncoder().encode(payload)
    #expect(data.count == 1024 * 1024)
    let overBoundary = try JSONEncoder().encode(Payload(value: payload.value + "x"))
    #expect(overBoundary.count == 1024 * 1024 + 1)
    try await withPeer([.reply(200, data), .reply(200, overBoundary), .stream(8 * 1024 * 1024)]) { server in
        let transport = try ClientTransport(origin: server.origin)
        let output: Payload = try await transport.invoke("notes.read", input: Empty())
        #expect(output.value == payload.value)
        await expectFailure("response_too_large", status: 200) {
            let _: Payload = try await transport.invoke("notes.read", input: Empty())
        }
        await expectFailure("response_too_large", status: 200) {
            let _: Payload = try await transport.invoke("notes.read", input: Empty())
        }
        await server.log.waitForCompletions(3)
        let completion = try #require(await server.log.completions.last)
        #expect(completion.disconnected)
        #expect(completion.sent < 8 * 1024 * 1024)
        #expect(await server.log.requests.count == 3)
    }
}

@Test func everyRedirectIsRejectedWithoutForwardingBearer() async throws {
    try await withPeer { destination in
        let statuses = Array(301...308)
        let responses = statuses.map {
            PeerResponse.reply($0, Data("{\"error\":\"moved\"}".utf8), ["Location": destination.origin + "/notes.read"])
        }
        try await withPeer(responses) { source in
            let transport = try ClientTransport(origin: source.origin).withBearer(String(repeating: "a", count: 43))
            for status in statuses {
                await expectFailure(status == 304 ? "invalid_response" : "moved", status: status) {
                    let _: Payload = try await transport.invoke("notes.read", input: Empty())
                }
            }
            await source.log.waitForCompletions(statuses.count)
            #expect(await source.log.requests.count == statuses.count)
            #expect(await destination.log.requests.count == 0)
        }
    }
}

@Test(arguments: [false, true]) func deadlineCancelsSilentAndTricklingPeers(headers: Bool) async throws {
    try await withPeer([.stall(headers), .reply(200, validBody)]) { server in
        let transport = try ClientTransport(origin: server.origin, timeout: 0.2)
        let start = ContinuousClock.now
        await expectFailure("timeout", status: headers ? 200 : nil) {
            let _: Payload = try await transport.invoke("notes.read", input: Empty())
        }
        #expect(start.duration(to: .now) < .seconds(2))
        await server.log.waitForCompletions(1)
        #expect(await server.log.completions.first?.disconnected == true)
        #expect(await server.log.requests.count == 1)
        let output: Payload = try await transport.invoke("notes.read", input: Empty())
        #expect(output.value == "ok")
    }
}

@Test func errorEnvelopeClassificationAndRedaction() async throws {
    let invalid = ["not JSON: secret", "{}", "{\"value\":\"secret\"}", "{\"error\":\"\"}",
                   "{\"error\":null}", "{\"error\":123}", "{\"error\":\"Bad-Code123\"}",
                   "{\"error\":\"bad code\"}", "{\"error\":\"code\\n\"}", "[]"]
    let responses = invalid.map { PeerResponse.reply(503, Data($0.utf8)) }
        + [.reply(409, Data("{\"error\":\"future_error_code\"}".utf8))]
    try await withPeer(responses) { server in
        let transport = try ClientTransport(origin: server.origin)
        for _ in invalid {
            let error = await expectFailure("invalid_response", status: 503) {
                let _: Payload = try await transport.invoke("notes.read", input: Empty())
            }
            #expect(error?.description.contains("secret") == false)
            #expect(error?.description.contains(server.origin) == false)
        }
        await expectFailure("future_error_code", status: 409) {
            let _: Payload = try await transport.invoke("notes.read", input: Empty())
        }
        #expect(await server.log.requests.count == responses.count)
    }
}

@Test func damagedSuccessfulResponsesAndNonObjectRootsAreRejected() async throws {
    let damaged = ["{}", "{\"value\":null}", "{\"value\":42}", "{\"value\":[]}", "null", "[]", "\"text\"", "{"]
    let encodings: [(String.Encoding, [UInt8])] = [
        (.utf16LittleEndian, []), (.utf16LittleEndian, [0xff, 0xfe]),
        (.utf16BigEndian, []), (.utf16BigEndian, [0xfe, 0xff]),
        (.utf32LittleEndian, []), (.utf32LittleEndian, [0xff, 0xfe, 0x00, 0x00]),
        (.utf32BigEndian, []), (.utf32BigEndian, [0x00, 0x00, 0xfe, 0xff]),
    ]
    let encodedResponses: [(Int, Data)] = try encodings.flatMap { encoding, bom in
        try [(200, "{\"value\":\"ok\"}"), (409, "{\"error\":\"denied\"}")].map { status, json in
            (status, Data(bom) + (try #require(json.data(using: encoding))))
        }
    }
    let invalidUTF8Responses: [(Int, Data)] = [
        (200, "{\"value\":\""), (200, "{\"value\":\"ok\",\"ignored\":\""),
        (409, "{\"error\":\""), (409, "{\"error\":\"denied\",\"ignored\":\""),
    ].map { ($0.0, Data($0.1.utf8) + Data([0xff]) + Data("\"}".utf8)) }
    let utf8BOM = Data([0xef, 0xbb, 0xbf])
    let responses = damaged.map { PeerResponse.reply(200, Data($0.utf8)) }
        + [.reply(200, Data("[]".utf8)), .reply(204, Data())]
        + encodedResponses.map { .reply($0.0, $0.1) }
        + [.reply(200, Data("{\"value\":\"\\u0000한글\"}".utf8))]
        + invalidUTF8Responses.map { .reply($0.0, $0.1) }
        + [.reply(200, utf8BOM + validBody),
           .reply(409, utf8BOM + Data("{\"error\":\"denied\"}".utf8))]
    try await withPeer(responses) { server in
        let transport = try ClientTransport(origin: server.origin)
        for _ in damaged {
            await expectFailure("invalid_response", status: 200) {
                let _: Payload = try await transport.invoke("notes.read", input: Empty())
            }
        }
        await expectFailure("invalid_response", status: 200) {
            let _: Empty = try await transport.invoke("notes.read", input: Empty())
        }
        await expectFailure("invalid_response", status: 204) {
            let _: Empty = try await transport.invoke("notes.read", input: Empty())
        }
        for (status, _) in encodedResponses {
            await expectFailure("invalid_response", status: status) {
                let _: Payload = try await transport.invoke("notes.read", input: Empty())
            }
        }
        let unicode: Payload = try await transport.invoke("notes.read", input: Empty())
        #expect(unicode.value == "\u{0}한글")
        for (status, _) in invalidUTF8Responses {
            await expectFailure("invalid_response", status: status) {
                let _: Payload = try await transport.invoke("notes.read", input: Empty())
            }
        }
        let bomOutput = try? await transport.invoke("notes.read", input: Empty(), as: Payload.self)
        #expect(bomOutput?.value == "ok")
        await expectFailure("denied", status: 409) {
            let _: Payload = try await transport.invoke("notes.read", input: Empty())
        }
        await expectFailure("invalid_input", status: nil) {
            let _: Payload = try await transport.invoke("notes.read", input: ["array"])
        }
        #expect(await server.log.requests.count == responses.count)
    }
}

@Test func connectionLossPreservesOnlyObservedStatusWithoutRetry() async throws {
    try await withPeer([.disconnect, .truncated]) { server in
        let transport = try ClientTransport(origin: server.origin)
        for status in [nil, 200] as [Int?] {
            let error = await expectFailure("transport_error", status: status) {
                let _: Payload = try await transport.invoke("notes.write", input: Empty())
            }
            #expect(error?.description.contains(server.origin) == false)
        }
        await server.log.waitForCompletions(2)
        #expect(await server.log.requests.count == 2)
    }
}

@Test func callerCancellationClosesTheActualRequest() async throws {
    try await withPeer([.stall(false)]) { server in
        let transport = try ClientTransport(origin: server.origin)
        let call = Task { () throws -> Payload in
            try await transport.invoke("notes.write", input: Empty())
        }
        await server.log.waitForRequests(1)
        call.cancel()
        await expectFailure("cancelled", status: nil) { _ = try await call.value }
        await server.log.waitForCompletions(1)
        #expect(await server.log.completions.first?.disconnected == true)
        let cancelled = Task { () throws -> Payload in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.invoke("notes.write", input: Empty())
        }
        await expectFailure("cancelled", status: nil) { _ = try await cancelled.value }
        #expect(await server.log.requests.count == 1)
    }
}
