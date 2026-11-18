import Foundation
@_spi(Conformance) import Chickinfry

let driverVersion = "1.0.0"
let capabilities = ["client.create", "client.copy", "client.call", "session.store", "barrier", "session.trace", "client.transport"]

private struct ClientEntry: Sendable {
    let transport: HTTPTransport
    let fixture: String
    let store: ObservedStore?
    let plain: PlainBridge?
    let auth: AuthBridge?
    let requiredAuth: RequiredAuthBridge?
    let emptySession: EmptySessionBridge?

    init(transport: HTTPTransport, fixture: String, store: ObservedStore?) {
        self.transport = transport
        self.fixture = fixture
        self.store = store
        plain = fixture == "plain" ? PlainBridge(transport) : nil
        auth = fixture == "auth" ? AuthBridge(transport) : nil
        requiredAuth = fixture == "requiredAuth" ? RequiredAuthBridge(transport) : nil
        emptySession = fixture == "emptySession" ? EmptySessionBridge(transport) : nil
    }
}

private struct Barrier {
    let point: String
    let participants: Set<String>
    var arrived: Set<String> = []
}

actor Driver {
    private var credentials: [String: String]
    private let secretValues: SecretValues
    private var clients: [String: ClientEntry] = [:]
    private var stores: [String: ObservedStore] = [:]
    private var barriers: [String: Barrier] = [:]
    private var requests: Set<String> = []
    private var tasks: [String: Task<Void, Never>] = [:]
    private var arrivals: [String: CheckedContinuation<Void, any Error>] = [:]
    private var arrivalBarriers: [String: String] = [:]
    private var callScopes: [String: (String, UInt64)] = [:]
    private var outgoing = 0
    private var negotiated = false
    private var activeCase: String?
    private var closing = false
    private let output: @Sendable (JSON) throws -> Void
    let observation = TransportObservation()

    init(credentials: [String: String], output: @escaping @Sendable (JSON) throws -> Void) {
        self.credentials = credentials
        self.secretValues = SecretValues(Set(credentials.values))
        self.output = output
    }

    func receive(_ message: JSON) throws {
        let id = try message.text("id")
        guard validRef(id) else { throw ProtocolFailure.violation }
        if message.object?["command"] == nil {
            try message.fields(["id", "result", "error"])
            guard id.hasPrefix("d:"), let continuation = arrivals.removeValue(forKey: id),
                  let ref = arrivalBarriers.removeValue(forKey: id) else { throw ProtocolFailure.violation }
            do {
                guard message["error"] == .null else { throw ProtocolFailure.violation }
                let result = message["result"]
                try result.fields(["barrierRef", "state", "sequence"])
                guard result["barrierRef"] == .string(ref), result["state"] == .string("released"),
                      let sequence = result["sequence"].integer, sequence > 0 else { throw ProtocolFailure.violation }
                continuation.resume()
            } catch {
                continuation.resume(throwing: error)
                throw error
            }
            return
        }
        try message.fields(["id", "command", "args"])
        guard !closing, id.hasPrefix("c:"), requests.insert(id).inserted else { throw ProtocolFailure.violation }
        let command = try message.text("command")
        let args = message["args"]
        if command == "handshake" {
            guard !negotiated, requests.count == 1 else { throw ProtocolFailure.violation }
            try args.fields(["protocolVersions", "runId", "requiredCapabilities", "target"])
            try args["target"].fields(["language", "role", "environment"])
            guard args["protocolVersions"].array?.contains(.int(1)) == true else {
                try reply(id, error: failure("protocol_mismatch"))
                closing = true
                return
            }
            guard let required = args["requiredCapabilities"].array,
                  required.allSatisfy({ $0.string.map(capabilities.contains) ?? false }) else {
                try reply(id, error: failure("unimplemented", kind: "unimplemented"))
                return
            }
            guard args["runId"].string.map(validRef) == true,
                  args["target"]["language"] == .string("swift"),
                  args["target"]["role"] == .string("sdk"), args["target"]["environment"].string != nil else {
                throw ProtocolFailure.violation
            }
            negotiated = true
            try reply(id, result: .object(["protocolVersion": .int(1), "driverVersion": .string(driverVersion),
                                           "capabilities": .array(capabilities.map(JSON.string))]))
            return
        }
        guard negotiated else { throw ProtocolFailure.violation }
        guard let timeout = args["timeoutMs"].integer, timeout > 0, timeout < Int.max / 1_000_000,
              args["caseId"].string.map(validRef) == true else { throw ProtocolFailure.violation }
        let caseID = try args.text("caseId")
        guard activeCase == nil || activeCase == caseID else { throw ProtocolFailure.violation }
        activeCase = caseID
        if command == "client.call" {
            observation.register(id)
            callScopes[id] = (try args.text("caseId"), DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000)
        }
        tasks[id] = Task {
            do {
                let result = try await withThrowingTaskGroup(of: JSON.self) { group in
                    group.addTask { try await self.execute(command, id: id, args: args) }
                    group.addTask {
                        try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000)
                        throw ProtocolFailure.deadline
                    }
                    defer { group.cancelAll() }
                    return try await group.next()!
                }
                try self.reply(id, result: result)
            } catch let error as ClientError {
                let descriptions = [error.description, error.localizedDescription, String(reflecting: error), error.code]
                let rawDetails = self.secretValues.values.contains { value in
                    !value.isEmpty && descriptions.contains { $0.contains(value) }
                }
                try? self.reply(id, error: .object([
                    "kind": .string("sdk"), "code": self.redact(.string(error.code)), "httpStatus": .optional(error.status),
                    "outcomeUnknown": self.callUnknown[id].map(JSON.bool) ?? .bool(false),
                    "rawTransportDetails": .bool(rawDetails),
                    "constructorNetworkRequests": command == "client.create" ? .optional(self.constructorCounts[id]) : .null,
                ].filter { $0.key != "constructorNetworkRequests" || command == "client.create" }))
            } catch let error as OperationError {
                let descriptions = [error.description, error.localizedDescription, String(reflecting: error), error.code]
                let rawDetails = self.secretValues.values.contains { value in
                    !value.isEmpty && descriptions.contains { $0.contains(value) }
                }
                try? self.reply(id, error: .object([
                    "kind": .string("sdk"), "code": self.redact(.string(error.code)), "httpStatus": .optional(error.status),
                    "outcomeUnknown": self.callUnknown[id].map(JSON.bool) ?? .bool(false),
                    "rawTransportDetails": .bool(rawDetails),
                    "constructorNetworkRequests": command == "client.create" ? .optional(self.constructorCounts[id]) : .null,
                ].filter { $0.key != "constructorNetworkRequests" || command == "client.create" }))
            } catch {
                let code: String
                switch error {
                case ProtocolFailure.invalidArgs: code = "invalid_args"
                case ProtocolFailure.invalidReference: code = "invalid_reference"
                case ProtocolFailure.unimplemented: code = "unimplemented"
                case ProtocolFailure.deadline: code = "deadline_exceeded"
                case ProtocolFailure.violation: code = "protocol_violation"
                default: code = "driver_failed"
                }
                try? self.reply(id, error: self.failure(code, kind: code == "unimplemented" ? "unimplemented" : "driver"))
            }
            self.tasks[id] = nil
        }
    }

    private var callUnknown: [String: Bool] = [:]
    private var constructorCounts: [String: Int] = [:]

    private func execute(_ command: String, id: String, args: JSON) async throws -> JSON {
        let common: Set<String> = ["caseId", "timeoutMs"]
        func fields(_ required: Set<String>, optional: Set<String> = []) throws {
            try args.fields(required.union(common), optional: optional)
        }
        func ref(_ name: String) throws -> String {
            let value = try args.text(name)
            guard validRef(value) else { throw ProtocolFailure.invalidArgs }
            return value
        }
        switch command {
        case "client.create":
            try fields(["clientRef", "fixture", "origin", "requestTimeoutMs"], optional: ["storeRef", "bearerRef"])
            let construction = Conformance.Construction()
            defer { constructorCounts[id] = construction.count }
            return try Conformance.$construction.withValue(construction) {
                let name = try ref("clientRef")
                guard clients[name] == nil, !(args.object?["storeRef"] != nil && args.object?["bearerRef"] != nil),
                      let timeout = args["requestTimeoutMs"].integer, timeout > 0 else { throw ProtocolFailure.invalidArgs }
                let fixture = try args.text("fixture")
                guard ["plain", "auth", "requiredAuth", "emptySession"].contains(fixture) else { throw ProtocolFailure.invalidArgs }
                var transport = try HTTPTransport(origin: args.text("origin"), timeout: Double(timeout) / 1000)
                var store: ObservedStore?
                if args.object?["storeRef"] != nil {
                    store = stores[try ref("storeRef")]
                    guard let store else { throw ProtocolFailure.invalidReference }
                    transport = try transport.withSession(store)
                }
                if args.object?["bearerRef"] != nil { transport = try transport.withBearer(credential(ref("bearerRef"))) }
                clients[name] = ClientEntry(transport: transport, fixture: fixture, store: store)
                return .object(["clientRef": .string(name), "constructorNetworkRequests": .int(construction.count)])
            }
        case "client.copy":
            try fields(["sourceClientRef", "clientRef", "bearerRef"])
            guard let source = clients[try ref("sourceClientRef")] else { throw ProtocolFailure.invalidReference }
            let name = try ref("clientRef")
            guard clients[name] == nil else { throw ProtocolFailure.invalidArgs }
            let transport = try source.transport.withBearer(credential(ref("bearerRef")))
            clients[name] = ClientEntry(transport: transport, fixture: source.fixture, store: nil)
            return .object(["clientRef": .string(name)])
        case "client.call":
            try fields(["clientRef", "operation", "input"], optional: ["inputRefs", "outputRefs"])
            guard let client = clients[try ref("clientRef")], var input = args["input"].object else {
                throw ProtocolFailure.invalidReference
            }
            if let references = args.object?["inputRefs"] {
                guard let references = references.object else { throw ProtocolFailure.invalidArgs }
                for (field, name) in references {
                    guard input[field] == nil, let name = name.string else { throw ProtocolFailure.invalidArgs }
                    input[field] = .string(try credential(name))
                }
            }
            var refs: [String: String] = [:]
            if let references = args.object?["outputRefs"] {
                guard let references = references.object else { throw ProtocolFailure.invalidArgs }
                for (field, name) in references {
                    guard let name = name.string, validRef(name), credentials[name] == nil,
                          !refs.values.contains(name) else { throw ProtocolFailure.invalidArgs }
                    refs[field] = name
                }
            }
            let operation = try args.text("operation")
            let observation = self.observation
            let credentials = self.credentials
            let secretValues = self.secretValues
            let context = Conformance.Call(event: { observation.record(id, event: $0) }, barrier: { point, flight in
                if point == "sdk-entered" { observation.start(id) }
                try await self.arrive(id: id, point: point, flight: flight)
            }, clear: { expected, removed in
                guard let store = client.store else { return }
                store.trace.record(.object([
                    "callId": .string(id), "expectedAccessRef": Self.reference(expected.accessToken, in: credentials),
                    "expectedRefreshRef": Self.reference(expected.refreshToken, in: credentials), "removed": .bool(removed),
                ]))
            }, credentials: { received in
                secretValues.insert(received.accessToken)
                secretValues.insert(received.refreshToken)
            })
            let raw: [String: JSON]
            do {
                raw = try await Conformance.$call.withValue(context) {
                    if let plain = client.plain { return try await plain.call(operation, input: .object(input)) }
                    if let required = client.requiredAuth { return try await required.call(operation, input: .object(input)) }
                    if let empty = client.emptySession { return try await empty.call(operation, input: .object(input)) }
                    return try await client.auth!.call(operation, input: .object(input))
                }
            } catch {
                callUnknown[id] = context.outcomeUnknown
                throw error
            }
            for field in ["access_token", "refresh_token", "password", "credential"] {
                if let value = raw[field]?.string { secretValues.insert(value) }
            }
            var registered: [String: JSON] = [:]
            for (field, name) in refs {
                guard let value = raw[field]?.string else { throw ProtocolFailure.invalidArgs }
                guard self.credentials[name] == nil else { throw ProtocolFailure.invalidArgs }
                self.credentials[name] = value
                self.secretValues.insert(value)
                registered[field] = .string(name)
            }
            for field in ["access_token", "refresh_token"] where registered[field] == nil {
                if let value = raw[field]?.string, case .string(let name) = Self.reference(value, in: self.credentials) {
                    registered[field] = .string(name)
                }
            }
            return .object(["output": redact(.object(raw)), "credentialRefs": .object(registered),
                            "httpStatus": .optional(observation.status(id))])
        case "client.observe":
            try fields(["callId", "afterSequence"])
            guard let after = args["afterSequence"].integer, after >= 0 else { throw ProtocolFailure.invalidArgs }
            return try observation.snapshot(args.text("callId"), after: after)
        case "session.store.create":
            try fields(["storeRef", "origin"], optional: ["recordRef", "accessRef", "refreshRef"])
            let name = try ref("storeRef")
            guard stores[name] == nil else { throw ProtocolFailure.invalidArgs }
            let store = try ObservedStore(origin: args.text("origin"))
            let supplied = ["recordRef", "accessRef", "refreshRef"].filter { args.object?[$0] != nil }
            if !supplied.isEmpty {
                guard supplied.count == 3 else { throw ProtocolFailure.invalidArgs }
                try await store.save(record(args, origin: store.origin))
            }
            stores[name] = store
            let state = await store.state()
            return .object(["storeRef": .string(name), "revision": .int(state.1)])
        case "session.store.write":
            try fields(["storeRef", "recordRef", "accessRef", "refreshRef"])
            guard let store = stores[try ref("storeRef")] else { throw ProtocolFailure.invalidReference }
            try await store.save(record(args, origin: store.origin))
            let state = await store.state()
            return .object(["revision": .int(state.1), "accessRef": args["accessRef"], "refreshRef": args["refreshRef"]])
        case "session.store.read":
            try fields(["storeRef", "includeTrace"])
            guard let store = stores[try ref("storeRef")] else { throw ProtocolFailure.invalidReference }
            guard let includeTrace = args["includeTrace"].bool else { throw ProtocolFailure.invalidArgs }
            let state = await store.state()
            let record = state.0
            var result: [String: JSON] = ["present": .bool(record != nil), "revision": .int(state.1),
                "accessRef": record.map { Self.reference($0.accessToken, in: credentials) } ?? .null,
                "refreshRef": record.map { Self.reference($0.refreshToken, in: credentials) } ?? .null]
            if includeTrace { result["clearAttempts"] = .array(state.2) }
            return .object(result)
        case "barrier.arm":
            try fields(["barrierRef", "point", "participants"])
            let name = try ref("barrierRef")
            let point = try args.text("point")
            guard ["sdk-entered", "both-originals-rejected", "refresh-joined"].contains(point) else {
                throw ProtocolFailure.unimplemented
            }
            guard barriers[name] == nil, let participants = args["participants"].array, !participants.isEmpty,
                  participants.allSatisfy({ $0.string.map { validRef($0) && $0.hasPrefix("c:") } ?? false }),
                  Set(participants.compactMap(\.string)).count == participants.count else { throw ProtocolFailure.violation }
            barriers[name] = Barrier(point: point, participants: Set(participants.compactMap(\.string)))
            return .object(["barrierRef": .string(name), "state": .string("armed")])
        default: throw ProtocolFailure.unimplemented
        }
    }

    private func credential(_ name: String) throws -> String {
        guard let value = credentials[name] else { throw ProtocolFailure.invalidReference }
        return value
    }

    private func record(_ args: JSON, origin: String) throws -> SessionRecord {
        var parser = try JSONParser(Data(credential(args.text("recordRef")).utf8))
        let value = try parser.parse()
        try value.fields(["origin", "access_token", "refresh_token", "expires_at", "refresh_expires_at", "user_id", "session_id"])
        guard try value.text("origin") == origin,
              try value.text("access_token") == credential(args.text("accessRef")),
              try value.text("refresh_token") == credential(args.text("refreshRef")) else { throw ProtocolFailure.invalidArgs }
        return try SessionRecord(origin: origin, accessToken: value.text("access_token"), refreshToken: value.text("refresh_token"),
                                 expiresAt: value.text("expires_at"), refreshExpiresAt: value.text("refresh_expires_at"),
                                 userID: value.text("user_id"), sessionID: value.text("session_id"))
    }

    private static func reference(_ value: String, in credentials: [String: String]) -> JSON {
        credentials.keys.sorted().first(where: { credentials[$0] == value }).map(JSON.string) ?? .null
    }

    private func redact(_ value: JSON) -> JSON {
        switch value {
        case .object(let values):
            return .object(values.filter { !["access_token", "refresh_token", "password", "credential"].contains($0.key) }
                .mapValues(redact))
        case .array(let values): return .array(values.map(redact))
        case .string(let value) where secretValues.values.contains(where: { !$0.isEmpty && value.contains($0) }): return .null
        default: return value
        }
    }

    private func arrive(id: String, point: String, flight: String?) async throws {
        let matches = barriers.filter { $0.value.point == point && $0.value.participants.contains(id) }.keys.sorted()
        for name in matches {
            guard !closing, barriers[name]!.arrived.insert(id).inserted else { throw ProtocolFailure.violation }
            outgoing += 1
            let request = "d:\(outgoing)"
            let now = DispatchTime.now().uptimeNanoseconds
            guard let (caseID, end) = callScopes[id], end > now else {
                throw ProtocolFailure.deadline
            }
            let timeout = max(1, Int((end - now) / 1_000_000))
            let facts: JSON = point == "sdk-entered" ? .object(["entered": .bool(true)])
                : point == "both-originals-rejected" ? .object(["httpStatus": .int(401)])
                : .object(["refreshRef": flight.map(JSON.string) ?? .null])
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    arrivals[request] = continuation
                    arrivalBarriers[request] = name
                    do {
                        try output(.object(["id": .string(request), "command": .string("barrier.arrive"), "args": .object([
                            "caseId": .string(caseID), "timeoutMs": .int(timeout),
                            "barrierRef": .string(name), "callId": .string(id), "point": .string(point), "facts": facts,
                        ])]))
                    } catch {
                        arrivals[request] = nil
                        arrivalBarriers[request] = nil
                        continuation.resume(throwing: error)
                    }
                }
            } onCancel: { Task { await self.cancelArrival(request) } }
        }
    }

    private func cancelArrival(_ id: String) {
        arrivalBarriers[id] = nil
        arrivals.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func failure(_ code: String, kind: String = "driver") -> JSON {
        .object(["kind": .string(kind), "code": .string(code), "httpStatus": .null, "outcomeUnknown": .null])
    }

    private func reply(_ id: String, result: JSON = .null, error: JSON = .null) throws {
        try output(.object(["id": .string(id), "result": result, "error": error]))
    }

    func shutdown() async {
        closing = true
        let outstanding = Array(tasks.values)
        for task in outstanding { task.cancel() }
        for id in Array(arrivals.keys) { cancelArrival(id) }
        for task in outstanding { await task.value }
        tasks = [:]
        for store in stores.values { await store.coordinator.conformanceShutdown() }
        clients = [:]
        stores = [:]
        credentials = [:]
        secretValues.removeAll()
    }

    var activeTaskCount: Int { tasks.count }
}
