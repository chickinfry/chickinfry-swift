import Foundation
@_spi(Conformance) import Chickinfry

private final class DecodeFailure: Error {}
private final class RecoveryFailure: Error {
    let cause = DecodeFailure()
}

actor RealtimeTrial {
    private let client: RealtimeClient
    private let readSnapshot: @Sendable () async throws -> Void
    private let origin: String
    private let channel: String
    private let mode: String
    private let handler: String
    private var job: Task<Void, Never>?
    private var subscription: RealtimeSubscription?
    private var facts: [String: JSON] = [
        "state": .string("ready"), "callbackStarts": .int(0), "callbackCompletions": .int(0),
        "callbackOverlapAtMost": .int(0), "dbReads": .int(0), "pendingReads": .int(0),
        "activeRenewalWatchers": .int(0), "deliveredAfterEnd": .int(0), "publicWireOperations": .int(0),
        "terminalErrors": .int(0), "staleFramesHeld": .int(0), "staleFramesDiscarded": .int(0),
    ]
    private var ids: [JSON] = []
    private var points: Set<String> = []
    private var waiters: [String: [AsyncStream<Void>.Continuation]] = [:]
    private var gates: [String: AsyncStream<Void>.Continuation] = [:]
    private var frames: [String: @Sendable () async -> Void] = [:]
    private var holding = false
    private var canceled = false
    private var gaps = 0
    private var callbacks = 0
    private var customer: RecoveryFailure?
    private var inspect: (@Sendable () async -> [String: Int])?

    init(client: RealtimeClient, plain: PlainBridge, origin: String, args: JSON) throws {
        guard origin.range(of: "^http://127\\.0\\.0\\.1:[0-9]+$", options: .regularExpression) != nil,
              args["transport"] == .string("plain") else { throw ProtocolFailure.invalidArgs }
        self.client = client
        self.origin = origin
        self.channel = try args.text("channel")
        self.mode = try args.text("onGap")
        self.handler = try args.text("eventHandler")
        guard ["hold", "absent", "fail", "cause"].contains(mode),
              ["normal", "hold-a"].contains(handler) else { throw ProtocolFailure.invalidArgs }
        readSnapshot = { _ = try await plain.call("probe.list", input: .object([:])) }
    }

    func start() {
        let endpoint = "ws://" + origin.dropFirst(7) + "/realtime"
        let probe = RealtimeProbe(endpoint: { value in
            guard value == endpoint else { throw ProtocolFailure.invalidArgs }
            return value
        }, point: { await self.wirePoint($0) }, inspect: { await self.setInspect($0) },
        dispatch: { await self.dispatch($0, $1) })
        job = Task { await RealtimeProbe.$current.withValue(probe) { await consume() } }
    }

    private func setInspect(_ read: @escaping @Sendable () async -> [String: Int]) {
        inspect = read
    }

    @discardableResult private func increment(_ name: String) -> Int {
        let count = (facts[name]?.integer ?? 0) + 1
        facts[name] = .int(count)
        return count
    }

    private func mark(_ point: String) {
        points.insert(point)
        for waiter in waiters.removeValue(forKey: point) ?? [] { waiter.finish() }
    }

    private func wirePoint(_ point: String) {
        switch point {
        case "gap":
            gaps += 1
            mark(gaps == 1 ? "gap-received" : "gap-received-again")
        case "discarded": increment("staleFramesDiscarded")
        case "overflow": mark("overflow-received")
        default: mark(point)
        }
    }

    private func parse(_ data: Data) throws -> JSON {
        var parser = try JSONParser(data)
        return try parser.parse()
    }

    private func dispatch(_ text: String, _ receive: @escaping @Sendable () async -> Void) async {
        if holding, let frame = try? parse(Data(text.utf8)),
           let type = frame["type"].string, ["ready", "event"].contains(type), frames[type] == nil {
            frames[type] = receive
            increment("staleFramesHeld")
            if frames.count == 2 { mark("stale-frames-held") }
        } else { await receive() }
    }

    private func hold(_ gate: String, point: String) async {
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        gates[gate] = continuation
        mark(point)
        for await _ in stream { }
    }

    private func recover() async throws {
        let count = increment("callbackStarts")
        callbacks += 1
        facts["callbackOverlapAtMost"] = .int(max(callbacks, facts["callbackOverlapAtMost"]?.integer ?? 0))
        defer { callbacks -= 1 }
        try await readSnapshot()
        increment("dbReads")
        if mode == "fail" || mode == "cause" {
            let error = RecoveryFailure()
            customer = error
            throw error
        }
        await hold("gap", point: count == 1 ? "gap-entered" : "gap-entered-again")
        if facts["state"] == .string("ready") { increment("callbackCompletions") }
    }

    private func consume() async {
        var phase = "subscribe"
        do {
            let options: SubscribeOptions = mode == "absent"
                ? .init() : .init(onGap: { _ in try await self.recover() })
            let result = try await client.subscribe(channel, options: options)
            subscription = result
            mark("subscribed")
            phase = "events"
            for try await event in result.events {
                let payload = try parse(event.payload)
                let id = try payload.text("id")
                guard ["A", "B", "C", "overflow"].contains(id) else { throw ProtocolFailure.invalidArgs }
                if facts["state"] != .string("ready") { increment("deliveredAfterEnd") }
                ids.append(.string(id))
                if id == "A" && handler == "hold-a" { await hold("event-a", point: "event-a-entered") }
                try Task.checkCancellation()
                mark("event-\(id.lowercased())-complete")
            }
            facts["state"] = .string(canceled ? "canceled" : "ended")
        } catch {
            if canceled || Task.isCancelled {
                facts["state"] = .string("canceled")
            } else {
                facts["state"] = .string("error")
                facts["errorPhase"] = .string(phase)
                facts["errorCode"] = .string((error as? ClientError)?.code ?? (error as? OperationError)?.code ?? "unknown")
                facts["httpStatus"] = .optional((error as? OperationError)?.status)
                increment("terminalErrors")
                if let cause = (error as NSError).userInfo[NSUnderlyingErrorKey] as? RecoveryFailure {
                    facts["causePreserved"] = .bool(cause === customer && cause.cause === customer?.cause)
                    facts["errorType"] = .string("RecoveryFailure")
                    facts["causeType"] = .string("DecodeFailure")
                }
            }
        }
        await subscription?.unsubscribe()
        mark("ended")
    }

    func command(_ name: String, args: JSON) async throws -> JSON {
        switch name {
        case "realtime.observe":
            let point = try args.text("point")
            if point != "snapshot", !points.contains(point) {
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                waiters[point, default: []].append(continuation)
                for await _ in stream { }
            }
            var snapshot = facts
            for (name, value) in await inspect?() ?? [:] where name != "connectionsStarted" {
                snapshot[name] = .int(value)
            }
            snapshot["eventIds"] = .array(ids)
            return .object(["facts": .object(snapshot)])
        case "realtime.release":
            guard let gate = gates.removeValue(forKey: try args.text("point")) else { throw ProtocolFailure.invalidArgs }
            gate.finish()
        case "realtime.unsubscribe":
            guard let subscription else { throw ProtocolFailure.invalidArgs }
            await subscription.unsubscribe()
            await subscription.unsubscribe()
            await job?.value
        case "realtime.cancel":
            await close()
        case "realtime.second-consumer":
            guard let subscription else { throw ProtocolFailure.invalidArgs }
            let before = await inspect?()["connectionsStarted"] ?? 0
            var rejected = false
            do {
                var iterator = subscription.events.makeAsyncIterator()
                _ = try await iterator.next()
            } catch let error as ClientError { rejected = error.code == "failed_precondition" }
            facts["exclusiveConsumption"] = .bool(rejected)
            facts["consumptionRejection"] = .string("runtime")
            facts["newConnections"] = .int((await inspect?()["connectionsStarted"] ?? 0) - before)
        case "realtime.hold-dispatch":
            holding = true
        case "realtime.release-dispatch":
            holding = false
            let release = frames
            frames.removeAll()
            for receive in release.values { await receive() }
        default:
            throw ProtocolFailure.invalidArgs
        }
        return .object(["accepted": .bool(true)])
    }

    func close() async {
        canceled = true
        job?.cancel()
        await job?.value
    }
}
