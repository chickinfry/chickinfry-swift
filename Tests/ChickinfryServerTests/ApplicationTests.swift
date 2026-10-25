#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Testing
@_spi(Generated) @testable import ChickinfryServer

private struct Input: Decodable, Sendable { let value: String }
private struct Output: Encodable, Sendable { let value: String }
private struct InternalFailure: Error {}

@Test func dispatchValidatesAndMasksFailures() async throws {
    let application = Application(operations: [
        Operation("echo.call", input: Input.self) { input, _ in Output(value: input.value) },
        Operation("echo.missing", input: Input.self) { _, _ -> Output in throw OperationError.notImplemented },
        Operation("echo.failed", input: Input.self) { _, _ -> Output in throw InternalFailure() },
        Operation("echo.databaseFailed", input: Input.self) { _, _ -> Output in throw HostFailure(code: "commit_unknown") },
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
        ("echo.databaseFailed", #"{"value":"x"}"#, 500, "operation_failed"),
        ("echo.unknown", "{}", 404, "not_found"),
    ] {
        let result = await application.handle(operation, body: Data(body.utf8), context: context)
        #expect(result.status == status)
        #expect(result.body == Data(#"{"error":"\#(code)"}"#.utf8))
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

@Test func invalidInputOmitsFieldsAndSkipsHandler() async {
    enum ItemID: String, Decodable, Sendable { case valid }
    struct Body: Decodable, Sendable { let item_id: ItemID; let nested: Input? }
    actor Calls {
        var count = 0
        func record() { count += 1 }
    }
    let calls = Calls()
    let application = Application(operations: [Operation("items.get", input: Body.self) { _, _ in
        await calls.record()
        return Output(value: "ok")
    }])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/items.get", headers: [:])
    for body in [
        "{}",
        #"{"item_id":12,"private_marker":"never reflect"}"#,
        #"{"item_id":null}"#,
        #"{"item_id":"valid","nested":{"value":12}}"#,
        #"{"item_id":"unknown"}"#,
    ] {
        let response = await application.handle("items.get", body: Data(body.utf8), context: context)
        #expect(response.status == 400)
        #expect(response.body == Data(#"{"error":"invalid_input"}"#.utf8))
        #expect(await calls.count == 0)
    }
}

@Test private func decodeBudgetErrorSkipsHandler() async {
    struct OverBudget: Decodable, Sendable {
        init(from decoder: any Decoder) throws { throw _InputBudgetExceeded() }
    }
    struct Invalid: Decodable, Sendable {
        init(from decoder: any Decoder) throws { throw InternalFailure() }
    }
    actor Calls {
        var count = 0
        func record() { count += 1 }
    }
    let calls = Calls()
    let application = Application(operations: [
        Operation("budget.call", input: OverBudget.self) { _, _ in
            await calls.record(); return Output(value: "unexpected")
        },
        Operation("invalid.call", input: Invalid.self) { _, _ in
            await calls.record(); return Output(value: "unexpected")
        },
    ])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/budget.call", headers: [:])
    for (operation, body, status, code) in [
        ("budget.call", "{}", 413, "request_too_large"),
        ("invalid.call", "{}", 400, "invalid_input"),
        ("budget.call", "{", 400, "invalid_json"),
        ("budget.call", #"{"x":0,"x":1}"#, 400, "invalid_input"),
    ] {
        let response = await application.handle(operation, body: Data(body.utf8), context: context)
        #expect(response.status == status)
        #expect(response.body == Data(#"{"error":"\#(code)"}"#.utf8))
        #expect(await calls.count == 0)
    }
}

private struct StructureCase: Sendable {
    let name: String
    let operation: String
    let body: Data
    let status: Int
    let error: String?
    let calls: Int

    init(_ name: String, _ body: String, operation: String = "catalog.create",
         status: Int = 400, error: String? = "invalid_input", calls: Int = 0) {
        self.name = name
        self.operation = operation
        self.body = Data(body.utf8)
        self.status = status
        self.error = error
        self.calls = calls
    }

    init(name: String, body: Data) {
        self.name = name
        self.operation = "catalog.create"
        self.body = body
        self.status = 400
        self.error = "invalid_json"
        self.calls = 0
    }
}

private let structureCases: [StructureCase] = {
    func nested(_ count: Int) -> String {
        String(repeating: "[", count: count) + "null" + String(repeating: "]", count: count)
    }
    func create(_ value: String) -> String {
        #"{"name":"structure","note":"ok","ignored":\#(value)}"#
    }
    func inspect(_ value: String) -> String {
        #"{"required_name":"required","nullable_name":null,"entries":[],"large_rows":[{"payload":"present","ignored":\#(value)}]}"#
    }
    return [
        StructureCase("unknown-depth-65", create(nested(64))),
        StructureCase("unknown-depth-64", create(nested(63)), status: 200, error: nil, calls: 1),
        StructureCase("declared-list-depth-64", inspect(nested(61)), operation: "catalog.inspect_optional",
                      status: 200, error: nil, calls: 1),
        StructureCase("unknown-positive-overflow", create("1e999")),
        StructureCase("nested-negative-overflow", inspect("-1e999"), operation: "catalog.inspect_optional"),
        StructureCase("unknown-finite-double", create("1e308"), status: 200, error: nil, calls: 1),
        StructureCase("reject-before-serialization", #"{"required_name":"required","nullable_name":null,"entries":[],"large_rows":[{"payload":"present"}],"ignored":\#(nested(19999))}"#,
                      operation: "catalog.inspect_optional"),
        StructureCase("invalid-json", #"{"name":"structure",}"#, error: "invalid_json"),
        StructureCase(name: "invalid-utf8", body: Data([123, 34, 255, 34, 58, 48, 125])),
        StructureCase("malformed-unclosed-depth-65", #"{"name":"structure","note":\#(String(repeating: "[", count: 65))}"#,
                      error: "invalid_json"),
        StructureCase("malformed-token-after-depth-65", #"{"name":"structure","note":\#(nested(65))!}"#,
                      error: "invalid_json"),
        StructureCase("bad-token-after-depth-20000", String(repeating: "[", count: 20000) + "!", error: "invalid_json"),
        StructureCase("syntax-after-overflow", create("1e999") + "!", error: "invalid_json"),
        StructureCase("auth-depth-65", create(nested(64)), operation: "auth.signIn"),
        StructureCase("auth-overflow", create("1e999"), operation: "auth.signIn"),
        StructureCase("auth-invalid-json", "{", operation: "auth.signIn", error: "invalid_json"),
        StructureCase("object-depth-65", create(String(repeating: #"{"x":"#, count: 64) + "null" + String(repeating: "}", count: 64))),
        StructureCase("object-depth-64", create(String(repeating: #"{"x":"#, count: 63) + "null" + String(repeating: "}", count: 63)),
                      status: 200, error: nil, calls: 1),
        StructureCase("string-brackets-and-escapes", create(#""[{}] \" \\ \u005b 1e999""#), status: 200, error: nil, calls: 1),
        StructureCase("string-unclosed-brackets", create("\"" + String(repeating: "[{", count: 65) + "\""),
                      status: 200, error: nil, calls: 1),
        StructureCase("duplicate-key", #"{"name":"structure","note":"ok","ignored":0,"ignored":1}"#),
        StructureCase("nested-duplicate-key", create(#"{"x":0,"x":1}"#)),
        StructureCase("escaped-duplicate-key", #"{"name":"structure","note":"ok","ign\u006fred":0,"ignored":1}"#),
        StructureCase("escaped-symbol-duplicate-key", create(#"{"a/b":0,"a\/b":1}"#)),
        StructureCase("surrogate-pair-duplicate-key", create(#"{"𝄞":0,"\uD834\uDD1E":1}"#)),
        StructureCase("empty-duplicate-key", create(#"{"":0,"":1}"#)),
        StructureCase("duplicate-key-overflow-overwritten", #"{"name":"structure","note":"ok","ignored":1e999,"ignored":0}"#),
        StructureCase("duplicate-key-depth-20000-overwritten",
                      #"{"name":"structure","note":"ok","ignored":\#(nested(19999)),"ignored":0}"#),
        StructureCase("unknown-integer-5000-digits", create(String(repeating: "9", count: 5000))),
        StructureCase("unknown-integer-300-digits", create(String(repeating: "9", count: 300)),
                      status: 200, error: nil, calls: 1),
        StructureCase("unknown-unpaired-high-surrogate-value", create(#""\ud800""#)),
        StructureCase("unknown-unpaired-low-surrogate-key", create(#"{"\udc00":0}"#)),
        StructureCase("unknown-unpaired-high-surrogate-key", create(#"{"\uD800":0}"#)),
        StructureCase("unknown-unpaired-low-surrogate-value", create(#""\uDC00""#)),
        StructureCase("reversed-surrogate-pair", create(#""\uDD1E\uD834""#)),
        StructureCase("high-surrogate-before-character", create(#""\uD800x""#)),
        StructureCase("high-surrogate-before-escape", create(#""\uD800\n""#)),
        StructureCase("high-surrogate-before-scalar-escape", create(#""\uD800\u0061""#)),
        StructureCase("repeated-high-surrogate", create(#""\uD800\uD834\uDD1E""#)),
        StructureCase("overwritten-surrogate-value", #"{"name":"structure","note":"ok","ignored":"\uD800","ignored":0}"#),
        StructureCase("syntax-after-duplicate-key", create(#"{"x":0,"x":1}"#) + "!", error: "invalid_json"),
        StructureCase("syntax-after-surrogate", create(#""\uD800""#) + "!", error: "invalid_json"),
        StructureCase("malformed-escape-after-surrogate", create(#""\uD800\u12xz""#), error: "invalid_json"),
        StructureCase("keys-in-separate-objects", create(#"[{"x":0},{"x":1}]"#),
                      status: 200, error: nil, calls: 1),
        StructureCase("canonically-equivalent-distinct-keys", create(#"{"\u00e9":0,"e\u0301":1}"#),
                      status: 200, error: nil, calls: 1),
        StructureCase("valid-surrogate-pairs", create(#"{"\uD834\uDD1E":"\uD800\uDC00\uDBFF\uDFFF"}"#),
                      status: 200, error: nil, calls: 1),
        StructureCase("duplicate-key-note", #"{"name":"structure","note":"a","note":"b"}"#),
        StructureCase("duplicate-key-escaped-name", create(#"{"na\u006de":0,"name":1}"#)),
        StructureCase("same-key-separate-objects-with-string-escapes", create(#"[{"name":"a\"}:[{\\x"},{"name":"b"}]"#),
                      status: 200, error: nil, calls: 1),
        StructureCase("large-shallow-array", create("[" + String(repeating: "null,", count: 100000) + "null]"),
                      status: 200, error: nil, calls: 1),
        StructureCase("scalar-root", "1"),
        StructureCase("null-root", "null"),
        StructureCase("array-root", "[]"),
        StructureCase("wrong-field-type", #"{"name":1,"note":"ok"}"#),
        StructureCase("finite-numbers-and-literals", create("[true,false,null,-0,0.25,1e-999,0e999,-1E+3]"),
                      status: 200, error: nil, calls: 1),
    ]
}()

@Test(arguments: structureCases.map(\.name))
private func requestStructureRejectsBeforeHandler(_ name: String) async {
    struct Create: Decodable, Sendable { let name: String; let note: String }
    struct Inspect: Decodable, Sendable {
        struct Row: Decodable, Sendable { let payload: String }
        let required_name: String
        let nullable_name: String?
        let entries: [String]
        let large_rows: [Row]
    }
    actor Calls {
        var count = 0
        func record() { count += 1 }
    }
    let test = structureCases.first { $0.name == name }!
    let calls = Calls()
    let application = Application(operations: [
        Operation("catalog.create", input: Create.self) { _, _ in
            await calls.record(); return Output(value: "ok")
        },
        Operation("catalog.inspect_optional", input: Inspect.self) { _, _ in
            await calls.record(); return Output(value: "ok")
        },
        Operation("auth.signIn", input: Create.self) { _, _ in
            await calls.record(); return Output(value: "ok")
        },
    ])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/\(test.operation)", headers: [:])
    let response = await application.handle(test.operation, body: test.body, context: context)
    #expect(response.status == test.status)
    if let error = test.error {
        #expect(response.body == Data(#"{"error":"\#(error)"}"#.utf8))
    } else {
        #expect(response.body == Data(#"{"value":"ok"}"#.utf8))
    }
    #expect(await calls.count == test.calls)
}

@Test(arguments: ["", "{", "[1,]", "{\"x\":1,}", "{\"x\" 1}", "{\"x\":}", "{x:1}",
                  "[1 2]", "[}", "{}{}", "true false", "{\"x\":01}", "{\"x\":-}",
                  "{\"x\":1.}", "{\"x\":1e}", "{\"x\":1e+}", "{\"x\":NaN}",
                  "{\"x\":Infinity}", "{\"x\":tru}", "{\"x\":\"\\q\"}", "{\"x\":\"\\u12xz\"}",
                  "{\"x\":\"newline\n\"}", "{\"x\":\"unfinished\\"])
private func malformedJSONSkipsHandler(_ body: String) async {
    let application = Application(operations: [Operation("echo.call", input: Input.self) { _, _ in
        Issue.record("Malformed JSON reached the handler")
        return Output(value: "unexpected")
    }])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/echo.call", headers: [:])
    let response = await application.handle("echo.call", body: Data(body.utf8), context: context)
    #expect(response.status == 400)
    #expect(response.body == Data(#"{"error":"invalid_json"}"#.utf8))
}

@Test private func requestBodyKeepsFourMiBLimit() async {
    actor Calls {
        var count = 0
        func record() { count += 1 }
    }
    let calls = Calls()
    let application = Application(operations: [Operation("echo.call", input: Input.self) { input, _ in
        await calls.record()
        return Output(value: input.value)
    }])
    let context = RequestContext(method: "POST", uri: "http://127.0.0.1/echo.call", headers: [:])
    var body = Data(#"{"value":"ok"}"#.utf8)
    body.append(Data(repeating: 32, count: (4 << 20) - body.count))
    let accepted = await application.handle("echo.call", body: body, context: context)
    #expect(accepted.status == 200)
    #expect(await calls.count == 1)
    body.append(32)
    let rejected = await application.handle("echo.call", body: body, context: context)
    #expect(rejected.status == 413)
    #expect(rejected.body == Data(#"{"error":"request_too_large"}"#.utf8))
    #expect(await calls.count == 1)
}
