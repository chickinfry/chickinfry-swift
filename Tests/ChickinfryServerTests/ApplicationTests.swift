#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@testable import ChickinfryServer

private struct Input: Decodable, Sendable { let value: String }
private struct Output: Encodable, Sendable { let value: String }
private struct InternalFailure: Error {}

@Test func dispatchValidatesAndMasksFailures() async throws {
    let application = Application(operations: [
        Operation("echo.call", input: Input.self) { input, _ in Output(value: input.value) },
        Operation("echo.missing", input: Input.self) { _, _ -> Output in throw OperationError.notImplemented },
        Operation("echo.failed", input: Input.self) { _, _ -> Output in throw InternalFailure() },
    ])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/echo.call", headers: [:])
    let response = await application.handle("echo.call", body: Data(#"{"value":"한글 🐔"}"#.utf8), context: context)
    #expect(response.status == 200)
    #expect(try JSONDecoder().decode(Input.self, from: response.body).value == "한글 🐔")
    for (operation, body, status, code) in [
        ("echo.call", "{}", 400, "invalid_input"),
        ("echo.call", #"{"value":null}"#, 400, "invalid_input"),
        ("echo.call", "[]", 400, "invalid_input"),
        ("echo.missing", #"{"value":"x"}"#, 501, "not_implemented"),
        ("echo.failed", #"{"value":"x"}"#, 500, "operation_failed"),
        ("echo.unknown", "{}", 404, "not_found"),
    ] {
        let result = await application.handle(operation, body: Data(body.utf8), context: context)
        #expect(result.status == status)
        #expect(String(decoding: result.body, as: UTF8.self).contains(#""error":"\#(code)""#))
        if status == 500 { #expect(result.body == Data(#"{"error":"operation_failed"}"#.utf8)) }
    }
}

@Test func suspendedRequestsKeepTheirOwnValues() async throws {
    let application = Application(operations: [Operation("echo.call", input: Input.self) { input, _ in
        if input.value == "slow" { try await Task.sleep(nanoseconds: 30_000_000) }
        return Output(value: input.value)
    }])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/echo.call", headers: [:])
    async let slow = application.handle("echo.call", body: Data(#"{"value":"slow"}"#.utf8), context: context)
    let fast = await application.handle("echo.call", body: Data(#"{"value":"fast"}"#.utf8), context: context)
    #expect(try JSONDecoder().decode(Input.self, from: fast.body).value == "fast")
    let slowResult = await slow
    #expect(try JSONDecoder().decode(Input.self, from: slowResult.body).value == "slow")
}

@Test func invalidFieldsUseDeclaredWireNamesWithoutReflectingValues() async throws {
    struct Body: Decodable, Sendable { let item_id: String }
    struct Failure: Decodable { struct Field: Decodable { let path: String; let code: String }; let fields: [Field] }
    let application = Application(operations: [Operation("items.get", input: Body.self) { _, _ in Output(value: "ok") }])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/items.get", headers: [:])
    for (body, code) in [("{}", "required"), (#"{"item_id":12,"private_marker":"never reflect"}"#, "invalid_type")] {
        let response = await application.handle("items.get", body: Data(body.utf8), context: context)
        let failure = try JSONDecoder().decode(Failure.self, from: response.body)
        #expect(failure.fields.count == 1)
        #expect(failure.fields[0].path == "item_id")
        #expect(failure.fields[0].code == code)
        #expect(!String(decoding: response.body, as: UTF8.self).contains("private_marker"))
    }
}
