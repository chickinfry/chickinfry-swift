import CoreFoundation
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

private let uuidPattern = "[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}"
private let reprepareMS = 30_000
let realtimeFrameSize = 66_560

private func completeMatch(_ value: String, _ pattern: String) -> Bool {
    value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
}

func realtimeEndpoint(_ value: String) throws -> String {
    guard completeMatch(value, "wss://" + uuidPattern + "\\.chickinfry\\.app/realtime") else {
        throw ClientError(code: "internal", status: nil)
    }
    return value
}

public struct RealtimeEvent: Sendable {
    public var type: String { "event" }
    public let channel: String
    public let payload: Data
}

public struct RealtimeGap: Sendable {
    public var type: String { "gap" }
    public let channel: String
}

public struct SubscribeOptions: Sendable {
    let onGap: (@Sendable (RealtimeGap) async throws -> Void)?

    public init(onGap: (@Sendable (RealtimeGap) async throws -> Void)? = nil) {
        self.onGap = onGap
    }
}

public struct RealtimeClient: Sendable {
    private let transport: any Transport

    @_spi(Generated) public init(transport: any Transport) { self.transport = transport }

    public func subscribe(_ channel: String, options: SubscribeOptions = .init()) async throws -> RealtimeSubscription {
        guard !channel.isEmpty, channel.utf8.count <= 128,
              !channel.utf8.contains(where: { $0 < 32 || $0 == 127 }) else {
            throw ClientError(code: "invalid_argument", status: nil)
        }
        let state = SubscriptionState(transport: transport, channel: channel, options: options, probe: RealtimeProbe.current)
        try await withTaskCancellationHandler {
            try await state.start()
        } onCancel: {
            Task { await state.stop() }
        }
        return RealtimeSubscription(events: .init(state: state))
    }
}

@_spi(Generated) public protocol RealtimeClientOwner {
    var realtime: RealtimeClient { get }
}

public struct RealtimeSubscription: Sendable {
    public let events: Events

    public func unsubscribe() async { await events.state.unsubscribe() }

    public struct Events: AsyncSequence, Sendable {
        public typealias Element = RealtimeEvent
        fileprivate let state: SubscriptionState

        public func makeAsyncIterator() -> Iterator { Iterator(state: state) }

        public struct Iterator: AsyncIteratorProtocol {
            fileprivate let state: SubscriptionState
            private let id = UUID()

            public mutating func next() async throws -> RealtimeEvent? {
                let state = state
                let id = id
                return try await withTaskCancellationHandler {
                    try await state.next(id)
                } onCancel: {
                    Task { await state.cancelConsumer(id) }
                }
            }
        }
    }
}

struct RealtimeRenewal: Sendable {
    let read: @Sendable () async throws -> SessionRecord?
    let refresh: @Sendable (SessionRecord) async throws -> Void
}

@_spi(Conformance) public struct RealtimeProbe: Sendable {
    let endpoint: @Sendable (String) throws -> String
    let point: @Sendable (String) async -> Void
    let inspect: @Sendable (@escaping @Sendable () async -> [String: Int]) async -> Void
    let dispatch: @Sendable (String, @escaping @Sendable () async -> Void) async -> Void

    public init(
        endpoint: @escaping @Sendable (String) throws -> String,
        point: @escaping @Sendable (String) async -> Void,
        inspect: @escaping @Sendable (@escaping @Sendable () async -> [String: Int]) async -> Void,
        dispatch: @escaping @Sendable (String, @escaping @Sendable () async -> Void) async -> Void
    ) {
        self.endpoint = endpoint
        self.point = point
        self.inspect = inspect
        self.dispatch = dispatch
    }

    #if CHICKINFRY_CONFORMANCE
    @TaskLocal public static var current: RealtimeProbe?
    #else
    static let current: RealtimeProbe? = nil
    #endif
}

private actor SubscriptionState {
    private struct Connection {
        let id: UUID
        let socket: RealtimeSocket
        var prepared = false
        var confirmation: String?
        var checkpoint: String?
    }

    private struct Recovery {
        let id = UUID()
        let cursor: String
        var complete = false
        var connection: UUID?
    }

    private struct Ticket: Decodable, Sendable { let endpoint: String; let ticket: String }
    private struct Empty: Encodable, Sendable {}

    private let transport: any Transport
    private let channel: String
    private let onGap: (@Sendable (RealtimeGap) async throws -> Void)?
    private let probe: RealtimeProbe?
    private let subscription = UUID().uuidString.lowercased()
    private var ready: CheckedContinuation<Void, any Error>?
    private var demand: CheckedContinuation<RealtimeEvent?, any Error>?
    private var consumer: UUID?
    private var queue: [(String, Data)] = []
    private var current: Connection?
    private var recovery: Recovery?
    private var deadline: Task<Void, Never>?
    private var runner: Task<Void, Never>?
    private var renewal: Task<Void, Never>?
    private var callback = false
    private var active = true
    private var firstReady = false
    private var failure: (any Error)?
    private var last = ""
    private var budgets = 0
    private var connections = 0
    private var backoff = 500

    init(transport: any Transport, channel: String, options: SubscribeOptions, probe: RealtimeProbe?) {
        self.transport = transport
        self.channel = channel
        self.onGap = options.onGap
        self.probe = probe
    }

    func start() async throws {
        await probe?.inspect { await self.metrics() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard active, !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
            ready = continuation
            armBudget()
            runner = Task { await run() }
            if let transport = transport as? HTTPTransport, let session = transport.realtimeRenewal() {
                renewal = Task { await renew(session) }
            }
        }
    }

    private func metrics() -> [String: Int] {
        ["pendingReads": demand == nil ? 0 : 1,
         "activeRenewalWatchers": active && renewal != nil ? 1 : 0,
         "reprepareBudgetMs": budgets > 0 ? reprepareMS : 0,
         "budgetResets": max(0, budgets - 1), "connectionsStarted": connections]
    }

    func next(_ id: UUID) async throws -> RealtimeEvent? {
        guard consumer == nil || consumer == id, demand == nil else {
            throw ClientError(code: "failed_precondition", status: nil)
        }
        consumer = id
        guard !Task.isCancelled else { stop(); throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            demand = continuation
            deliver()
        }
    }

    func cancelConsumer(_ id: UUID) {
        if consumer == nil || consumer == id { stop() }
    }

    private func deliver() {
        guard let demand else { return }
        if !active {
            self.demand = nil
            let terminal = failure
            failure = nil
            demand.resume(with: terminal.map { .failure($0) } ?? .success(nil))
        } else if recovery != nil {
            recover()
        } else if let current, current.prepared, !queue.isEmpty {
            let (cursor, payload) = queue.removeFirst()
            last = cursor
            self.demand = nil
            demand.resume(returning: .init(channel: channel, payload: payload))
            if queue.isEmpty, current.checkpoint != nil { Task { await acknowledge(current.id) } }
        }
    }

    func unsubscribe() async {
        if let current {
            _ = try? await CallDeadline(timeout: 1).wait {
                await self.send(on: current, type: "unsubscribe")
            }
        }
        stop()
    }

    func stop(_ error: (any Error)? = nil) {
        guard active else { return }
        active = false
        failure = error
        recovery = nil
        close()
        deadline?.cancel()
        runner?.cancel()
        renewal?.cancel()
        ready?.resume(throwing: error ?? ClientError(code: "canceled", status: nil))
        ready = nil
        deliver()
    }

    private func close() {
        let old = current
        current = nil
        queue.removeAll()
        old?.socket.close()
    }

    private func armBudget() {
        guard deadline == nil else { return }
        if firstReady { budgets += 1 }
        deadline = Task {
            do { try await Task.sleep(nanoseconds: UInt64(reprepareMS) * 1_000_000) }
            catch { return }
            stop(ClientError(code: "deadline_exceeded", status: nil))
        }
    }

    private func gap(_ cursor: String) async {
        guard onGap != nil else { stop(ClientError(code: "data_loss", status: nil)); return }
        recovery = Recovery(cursor: cursor)
        current?.prepared = false
        queue.removeAll()
        armBudget()
        await probe?.point("gap")
        recover()
    }

    private func recover() {
        guard active, !callback, let recovery, !recovery.complete, let onGap,
              !firstReady || demand != nil else { return }
        callback = true
        Task {
            defer { callback = false; recover() }
            guard active, self.recovery?.id == recovery.id else { return }
            do {
                try await onGap(.init(channel: channel))
                guard active, self.recovery?.id == recovery.id else { return }
                self.recovery?.complete = true
                last = recovery.cursor
                close()
            } catch {
                guard active, self.recovery?.id == recovery.id else { return }
                stop(ClientError(code: "unknown", status: nil, underlying: error))
            }
        }
    }

    private func send(on connection: Connection, type: String, fields: [String: String] = [:]) async -> Bool {
        do {
            let frame = fields.merging(["type": type, "channel": channel]) { _, value in value }
            let text = String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
            try await connection.socket.send(text)
            return active && current?.id == connection.id
        } catch {
            connection.socket.close()
            return false
        }
    }

    private func acknowledge(_ id: UUID) async {
        guard let connection = current, connection.id == id, connection.prepared,
              recovery == nil, queue.isEmpty, let cursor = connection.checkpoint else { return }
        current?.checkpoint = nil
        _ = await send(on: connection, type: "ack", fields: ["cursor": cursor])
    }

    private func cursor(_ value: Any?) throws -> String {
        guard let value = value as? String, value.isEmpty || completeMatch(value, uuidPattern) else {
            throw ClientError(code: "internal", status: nil)
        }
        return value
    }

    private func receive(_ text: String, _ id: UUID) async {
        guard active, let connection = current, connection.id == id else {
            await probe?.point("discarded")
            return
        }
        do {
            guard text.utf8.count <= realtimeFrameSize,
                  let frame = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let type = frame["type"] as? String,
                  frame["channel"] as? String == channel || (type == "error" && frame["channel"] == nil)
            else { throw ClientError(code: "internal", status: nil) }
            switch type {
            case "ready":
                let cursor = try cursor(frame["cursor"])
                let nonce = frame["confirmation"] as? String
                let rawAck = frame["acknowledge"]
                let ack = rawAck.flatMap {
                    CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() ? $0 as? Bool : nil
                }
                guard (frame["confirmation"] == nil || nonce.map({ completeMatch($0, uuidPattern) }) == true),
                      frame["acknowledge"] == nil || ack != nil else { throw ClientError(code: "internal", status: nil) }
                current?.checkpoint = ack == true ? cursor : nil
                if nonce == nil {
                    if connection.confirmation == nil {
                        let confirmation = UUID().uuidString.lowercased()
                        current?.confirmation = confirmation
                        _ = await send(on: connection, type: "confirm", fields: ["confirmation": confirmation])
                    }
                    return
                }
                guard nonce == connection.confirmation else { return }
                if let recovery {
                    guard recovery.complete, recovery.connection == id else { return }
                    self.recovery = nil
                    await probe?.point("recovered")
                    guard active, current?.id == id else { return }
                }
                current?.prepared = true
                firstReady = true
                deadline?.cancel()
                deadline = nil
                ready?.resume()
                ready = nil
                await acknowledge(id)
                deliver()
            case "gap":
                try await gap(cursor(frame["cursor"]))
            case "event":
                let next = try cursor(frame["cursor"])
                let previous = try cursor(frame["previous"])
                guard !next.isEmpty, let payload = frame["payload"] else { throw ClientError(code: "internal", status: nil) }
                guard next != last, !queue.contains(where: { $0.0 == next }) else { return }
                let expected = queue.last?.0 ?? recovery?.cursor ?? last
                let full = queue.count >= (probe == nil ? 256 : 512)
                if previous != expected || full {
                    if full { await probe?.point("overflow") }
                    await gap(next)
                } else {
                    queue.append((next, try JSONSerialization.data(withJSONObject: payload, options: .fragmentsAllowed)))
                    deliver()
                }
            case "error":
                guard let code = frame["error"] as? String, completeMatch(code, "[a-z_]{1,64}") else {
                    throw ClientError(code: "internal", status: nil)
                }
                let mapped: String = switch code {
                case "unauthorized_channel": "permission_denied"
                case "already_subscribed": "internal"
                case "too_many_channels": "resource_exhausted"
                case "replay_failed", "realtime_unavailable": "unavailable"
                default: "unknown"
                }
                stop(ClientError(code: mapped, status: nil))
            default:
                throw ClientError(code: "internal", status: nil)
            }
        } catch {
            stop(ClientError(code: "internal", status: nil))
        }
    }

    private func run() async {
        while active && !Task.isCancelled {
            do {
                let ticket = try await transport.invoke("realtime.ticket", input: Empty(), as: Ticket.self)
                guard active else { return }
                guard completeMatch(ticket.ticket, uuidPattern) else { throw ClientError(code: "internal", status: nil) }
                let endpoint = try probe?.endpoint(ticket.endpoint) ?? realtimeEndpoint(ticket.endpoint)
                guard let address = URL(string: endpoint + "?ticket=" + ticket.ticket) else {
                    throw ClientError(code: "internal", status: nil)
                }
                let id = UUID()
                do {
                    try await withRealtimeSocket(address, opened: { socket in
                        await self.opened(socket, id: id)
                    }, received: { text in
                        await self.received(text, id: id)
                    })
                } catch let error as ClientError where error.code == "internal" {
                    stop(error)
                } catch { }
                if current?.id == id { close() }
                if active { armBudget() }
            } catch let error as OperationError {
                let status = error.status ?? 0
                if !((status == 409 && !firstReady) || status == 429 || status >= 500) { stop(error) }
            } catch let error as ClientError {
                if error.code != "unavailable" && error.code != "deadline_exceeded" { stop(error) }
            } catch {
                stop(ClientError(code: "internal", status: nil))
            }
            if active {
                do { try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000) }
                catch { return }
                backoff = min(backoff * 2, 5000)
            }
        }
    }

    private func opened(_ socket: RealtimeSocket, id: UUID) async -> Bool {
        guard active else { return false }
        let connection = Connection(id: id, socket: socket)
        current = connection
        connections += 1
        if recovery?.complete == true { recovery?.connection = id }
        let cursor = recovery?.cursor ?? last
        let sent = try? await CallDeadline(timeout: 10).wait {
            await self.send(on: connection, type: "subscribe", fields: ["cursor": cursor, "subscription": self.subscription])
        }
        guard sent == true else { return false }
        backoff = 500
        return true
    }

    private func received(_ text: String, id: UUID) async -> Bool {
        if let probe {
            await probe.dispatch(text) { await self.receive(text, id) }
        } else {
            await receive(text, id)
        }
        return active && current?.id == id
    }

    private func renew(_ session: RealtimeRenewal) async {
        let precise = ISO8601DateFormatter()
        precise.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standard = ISO8601DateFormatter()
        do {
            while active {
                guard let record = try await session.read() else { throw ClientError(code: "unauthenticated", status: nil) }
                guard let expires = precise.date(from: record.expiresAt) ?? standard.date(from: record.expiresAt) else {
                    throw ClientError(code: "internal", status: nil)
                }
                let wait = max(0, expires.timeIntervalSinceNow - 60)
                try await Task.sleep(nanoseconds: UInt64(min(wait, 86_400) * 1_000_000_000))
                if wait <= 86_400, try await session.read()?.credential == record.credential {
                    try await session.refresh(record)
                    if try await session.read()?.credential == record.credential {
                        throw ClientError(code: "internal", status: nil)
                    }
                }
            }
        } catch is CancellationError { }
        catch { stop(error) }
    }
}
