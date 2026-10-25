import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The JSON operation boundary used by generated clients.
public struct ClientTransport: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let origin: String
    private let timeout: TimeInterval
    private let bearer: String?
    private let store: (any SessionStore)?

    // Default reflection includes private credentials, so expose no stored properties.
    public var description: String { "ClientTransport" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: EmptyCollection<Mirror.Child>(), displayStyle: .struct)
    }

    public init(origin: String, timeout: TimeInterval = 30) throws {
        self.origin = try Self.validateOrigin(origin)
        // The SDK deadline must also fit the monotonic nanosecond timer.
        guard timeout.isFinite, timeout > 0, timeout < Double(Int64.max) / 1_000_000_000 else {
            throw OperationError(code: "invalid_input", status: nil)
        }
        self.timeout = timeout
        self.bearer = nil
        self.store = nil
    }

    private init(origin: String, timeout: TimeInterval, bearer: String?, store: (any SessionStore)?) {
        self.origin = origin
        self.timeout = timeout
        self.bearer = bearer
        self.store = store
    }

    /// Returns an explicit bearer copy, without session storage or automatic refresh.
    public func withBearer(_ token: String) throws -> Self {
        try Self.validateToken(token)
        return Self(origin: origin, timeout: timeout, bearer: token, store: nil)
    }

    /// Uses the store's shared refresh coordinator; the original transport is unchanged.
    public func withSession(_ store: any SessionStore) throws -> Self {
        guard store.origin == origin else { throw OperationError(code: "invalid_origin", status: nil) }
        return Self(origin: origin, timeout: timeout, bearer: nil, store: store)
    }

    @_spi(DeviceStorage)
    public func rejectAuthentication(_ before: DeviceSnapshot) async throws {
        if let device = store as? any DeviceAuthenticationStore { try await device.rejectAuthentication(before) }
    }

    @_spi(DeviceStorage)
    public func acceptSession(_ session: SessionRecord, after before: DeviceSnapshot,
                               consuming attempt: DeviceAttempt? = nil,
                               confirmedEmail: String? = nil) async throws -> SessionRecord {
        guard session.origin == origin else { throw OperationError(code: "invalid_origin", status: nil) }
        guard let store else { return session }
        var value = session
        value.deviceGeneration = before.generation
        value.deviceAuthGeneration = before.authGeneration
        let accepted = value
        let generation = try await store.coordinator.targetAuthenticationGeneration(before, session: session, consuming: attempt)
        _ = try await store.coordinator.acceptAuthenticated(accepted, store: store, authGeneration: generation,
                                                           localAuthGeneration: before.localAuthGeneration, lateIsEmpty: true,
                                                           recovery: DeviceRecovery(before: before, writtenSession: accepted, writtenAuthGeneration: generation, session: accepted,
                                                                                    authGeneration: generation, consuming: attempt,
                                                                                    consumingEmail: attempt?.email ?? confirmedEmail, ownsRefresh: false)) {
            if let device = store as? any DeviceAuthenticationStore {
                return try await store.coordinator.commitAuthentication(accepted, store: device, before: before,
                                                                         consuming: attempt, confirmedEmail: confirmedEmail)
            }
            try await store.save(accepted)
            return .persisted
        }
        return session
    }

    static func validateToken(_ token: String) throws {
        guard token.utf8.count == 43,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw OperationError(code: "invalid_token", status: nil)
        }
    }

    public func invoke<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ operation: String, input: Input, as outputType: Output.Type = Output.self
    ) async throws -> Output {
        let deadline = CallDeadline(timeout: timeout)
        #if CHICKINFRY_CONFORMANCE
        let observation = Conformance.call
        defer {
            observation?.select()
            observation?.observe("completed", immediate: true)
        }
        try await observation?.barrier("sdk-entered", nil)
        #endif
        _ = try deadline.remaining()
        guard operation.range(of: "\\A[A-Za-z_][A-Za-z0-9_]*\\.[A-Za-z_][A-Za-z0-9_]*\\z",
                              options: .regularExpression) != nil else {
            throw OperationError(code: "invalid_input", status: nil)
        }
        let body: Data
        do {
            body = try JSONEncoder().encode(input)
        } catch {
            throw OperationError(code: "invalid_input", status: nil)
        }
        guard body.count <= 4 * 1024 * 1024 else {
            throw OperationError(code: "request_too_large", status: nil)
        }
        guard (try? JSONSerialization.jsonObject(with: body)) is [String: Any],
              let url = URL(string: origin + "/" + operation) else {
            throw OperationError(code: "invalid_input", status: nil)
        }
        let stored: SessionRecord?
        if let store {
            stored = try await deadline.wait { try await loadSession(store, origin: origin) }
        } else { stored = nil }
        do {
            do {
                return try await exchange(url: url, body: body, bearer: stored?.accessToken ?? bearer,
                                          deadline: deadline, as: outputType,
                                          finalExchange: stored == nil || operation == "auth.refresh")
            } catch let rejection as ServerRejection where rejection.error.code == "invalid_token" && rejection.error.status == 401 {
                #if CHICKINFRY_CONFORMANCE
                try await observation?.barrier("both-originals-rejected", nil)
                #endif
                let error = rejection.error
                guard operation != "auth.refresh", let store, let stored else { throw error }
                let refreshed = try await deadline.wait {
                    try await store.coordinator.refresh(expected: stored, store: store) {
                        let refreshDeadline = CallDeadline(timeout: timeout)
                        let input = RefreshInput(refresh_token: stored.refreshToken)
                        let bytes = try JSONEncoder().encode(input)
                        let output: RefreshOutput = try await exchange(
                            url: URL(string: origin + "/auth.refresh")!, body: bytes, bearer: nil,
                            deadline: refreshDeadline, as: RefreshOutput.self)
                        let refreshed = try output.record(origin: origin)
                        #if CHICKINFRY_CONFORMANCE
                        observation?.credentials(refreshed)
                        #endif
                        return refreshed
                    }
                }
                guard let refreshed else { throw error }
                return try await exchange(url: url, body: body, bearer: refreshed.accessToken,
                                          deadline: deadline, as: outputType, finalExchange: true)
            }
        } catch let rejection as ServerRejection {
            throw rejection.error
        }
    }

    private func exchange<Output: Decodable & Sendable>(
        url: URL, body: Data, bearer: String?, deadline: CallDeadline, as outputType: Output.Type,
        finalExchange: Bool = false
    ) async throws -> Output {
        #if CHICKINFRY_CONFORMANCE
        let observation = Conformance.call
        observation?.exchange(immediate: finalExchange)
        #endif
        let remaining = try deadline.remaining()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }

        let receiver = ResponseReceiver()
        #if CHICKINFRY_CONFORMANCE
        receiver.observation = observation
        #endif
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = remaining
        configuration.timeoutIntervalForResource = remaining
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        let networkTimeout = try deadline.remaining()
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(task: task, timeout: networkTimeout, continuation: continuation)
            }
        } onCancel: {
            receiver.fail(code: "cancelled")
        }
        guard let status = response.status else {
            throw OperationError(code: "invalid_response", status: nil)
        }
        #if CHICKINFRY_CONFORMANCE
        observation?.inspect(Conformance.Buffers(
            exchange: response.observationID, response: { [weak response] in response?.body.count ?? 0 }, accumulated: { 0 },
            holdOwner: { [weak response] in
                guard let response else { return nil }
                return { withExtendedLifetime(response) {} }
            }))
        #endif
        guard Self.validUTF8(response.body) else {
            throw OperationError(code: "invalid_response", status: status)
        }
        if !(200..<300).contains(status) {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)
            let code = envelope?.error
            let valid = code?.range(of: "\\A[a-z_]+\\z", options: .regularExpression) != nil
            guard valid else { throw OperationError(code: "invalid_response", status: status) }
            #if CHICKINFRY_CONFORMANCE
            observation?.confirmedOutcome()
            #endif
            throw ServerRejection(error: OperationError(code: code!, status: status))
        }
        let output: Output
        do {
            guard (try JSONSerialization.jsonObject(with: response.body)) is [String: Any] else {
                throw OperationError(code: "invalid_response", status: status)
            }
            output = try JSONDecoder().decode(outputType, from: response.body)
        } catch {
            throw OperationError(code: "invalid_response", status: status)
        }
        do { _ = try deadline.remaining() }
        catch let error as OperationError { throw OperationError(code: error.code, status: status) }
        #if CHICKINFRY_CONFORMANCE
        observation?.confirmedOutcome()
        #endif
        return output
    }

    private static func validUTF8(_ body: Data) -> Bool {
        var decoder = UTF8()
        var iterator = body.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let value): if value.value == 0 { return false }
            case .emptyInput: return true
            case .error: return false
            }
        }
    }

    static func validateOrigin(_ raw: String) throws -> String {
        let failure = OperationError(code: "invalid_origin", status: nil)
        // Inspect the raw authority before Foundation can normalize numeric hosts or escapes.
        guard !raw.contains("?"), !raw.contains("#"), !raw.contains("@"),
              !raw.contains("%"), !raw.contains("\\"),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0)
                  || CharacterSet.controlCharacters.contains($0) }),
              let separator = raw.range(of: "://") else { throw failure }
        let scheme = String(raw[..<separator.lowerBound]).lowercased()
        guard scheme == "https" || scheme == "http" else { throw failure }
        let suffix = String(raw[separator.upperBound...])
        let authority = suffix.hasSuffix("/") ? String(suffix.dropLast()) : suffix
        guard !authority.isEmpty, !authority.contains("/"),
              let components = URLComponents(string: raw),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/",
              components.url != nil else { throw failure }
        let rawHost: String
        let portText: String?
        if authority.hasPrefix("[") {
            guard let end = authority.firstIndex(of: "]") else { throw failure }
            rawHost = String(authority[...end])
            let remainder = String(authority[authority.index(after: end)...])
            guard remainder.isEmpty || remainder.hasPrefix(":") else { throw failure }
            portText = remainder.isEmpty ? nil : String(remainder.dropFirst())
        } else {
            let pieces = authority.split(separator: ":", omittingEmptySubsequences: false)
            guard pieces.count <= 2 else { throw failure }
            rawHost = String(pieces[0])
            portText = pieces.count == 2 ? String(pieces[1]) : nil
        }
        guard host.lowercased() == rawHost.lowercased() else { throw failure }
        if let portText {
            guard !portText.isEmpty, portText.utf8.allSatisfy({ (48...57).contains($0) }),
                  let port = Int(portText), (1...65535).contains(port), components.port == port else {
                throw failure
            }
        }
        if scheme == "http", rawHost != "[::1]" {
            let octets = rawHost.split(separator: ".", omittingEmptySubsequences: false)
            guard octets.count == 4, octets.first == "127",
                  octets.allSatisfy({ part in
                      guard let value = Int(part), (0...255).contains(value) else { return false }
                      return String(value) == part
                  }) else { throw failure }
        }
        return scheme + "://" + authority
    }
}

private struct RefreshInput: Encodable { let refresh_token: String }
private struct RefreshOutput: Decodable, Sendable {
    let access_token: String
    let refresh_token: String
    let expires_at: String
    let refresh_expires_at: String
    let user_id: String
    let session_id: String

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        access_token = try values.decode(String.self, forKey: .access_token)
        refresh_token = try values.decode(String.self, forKey: .refresh_token)
        expires_at = try values.decode(String.self, forKey: .expires_at)
        refresh_expires_at = try values.decode(String.self, forKey: .refresh_expires_at)
        user_id = try values.decode(String.self, forKey: .user_id)
        session_id = try values.decode(String.self, forKey: .session_id)
        try ClientTransport.validateToken(access_token)
        try ClientTransport.validateToken(refresh_token)
        guard !expires_at.isEmpty, !refresh_expires_at.isEmpty, !user_id.isEmpty, !session_id.isEmpty else {
            throw OperationError(code: "invalid_response", status: nil)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case access_token, refresh_token, expires_at, refresh_expires_at, user_id, session_id
    }

    func record(origin: String) throws -> SessionRecord {
        try SessionRecord(origin: origin, accessToken: access_token, refreshToken: refresh_token,
                          expiresAt: expires_at, refreshExpiresAt: refresh_expires_at,
                          userID: user_id, sessionID: session_id)
    }
}

// Only a fully received and decoded server error envelope carries this provenance.
struct ServerRejection: Error { let error: OperationError }

private struct ErrorEnvelope: Decodable { let error: String }
private final class ReceivedResponse: @unchecked Sendable {
    let body: Data
    let status: Int?
    #if CHICKINFRY_CONFORMANCE
    var observation: Conformance.Call?
    var observationID = UUID()
    deinit { observation?.account(-body.count) }
    #endif

    init(body: Data, status: Int?) {
        self.body = body
        self.status = status
    }
}

// All delegate, cancellation, and deadline state is protected by the same lock.
private final class ResponseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var status: Int?
    private var task: URLSessionDataTask?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<ReceivedResponse, any Error>?
    private var finished = false
    #if CHICKINFRY_CONFORMANCE
    var observation: Conformance.Call?
    private let construction = Conformance.construction
    private let refreshTransmission = Conformance.refreshTransmission
    private let observationID = UUID()
    private var immediate = false
    private var observationIsImmediate: Bool { lock.withLock { immediate } }
    #endif

    func start(task: URLSessionDataTask, timeout: TimeInterval,
               continuation: CheckedContinuation<ReceivedResponse, any Error>) {
        let alreadyCancelled = lock.withLock {
            guard !finished else { return true }
            self.task = task
            self.continuation = continuation
            let deadlineTime = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
            deadline = Task {
                let now = DispatchTime.now().uptimeNanoseconds
                do { try await Task.sleep(nanoseconds: deadlineTime > now ? deadlineTime - now : 0) }
                catch { return }
                self.fail(code: "timeout")
            }
            #if CHICKINFRY_CONFORMANCE
            construction?.networkEntry()
            #endif
            task.resume()
            return false
        }
        if alreadyCancelled {
            #if CHICKINFRY_CONFORMANCE
            observation?.observe("cancel-requested", immediate: true)
            #endif
            task.cancel()
            continuation.resume(throwing: OperationError(code: "cancelled", status: nil))
        }
    }

    func fail(code: String) { finish(code: code) }

    private func finish(code: String?, cancelTask: Bool = true) {
        let completion = lock.withLock { () -> (
            CheckedContinuation<ReceivedResponse, any Error>?, URLSessionDataTask?, Task<Void, Never>?,
            ReceivedResponse
        )? in
            guard !finished else { return nil }
            finished = true
            if status == nil { status = (task?.response as? HTTPURLResponse)?.statusCode }
            let response = ReceivedResponse(body: body, status: status)
            #if CHICKINFRY_CONFORMANCE
            response.observation = observation
            response.observationID = observationID
            #endif
            let result = (continuation, task, deadline, response)
            continuation = nil
            task = nil
            deadline = nil
            body = Data()
            return result
        }
        guard let (continuation, task, deadline, response) = completion else { return }
        deadline?.cancel()
        if let code {
            if cancelTask, let task {
                #if CHICKINFRY_CONFORMANCE
                observation?.observe("cancel-requested", immediate: observationIsImmediate)
                #endif
                task.cancel()
            }
            continuation?.resume(throwing: OperationError(code: code, status: response.status))
        } else {
            continuation?.resume(returning: response)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let active = lock.withLock {
            guard !finished else { return false }
            status = (response as? HTTPURLResponse)?.statusCode
            #if CHICKINFRY_CONFORMANCE
            immediate = status.map {
                (300..<400).contains($0) || ($0 != 401 && refreshTransmission == nil)
            } ?? false
            #endif
            return true
        }
        #if CHICKINFRY_CONFORMANCE
        if active {
            observation?.observe("headers", status: (response as? HTTPURLResponse)?.statusCode,
                                 immediate: observationIsImmediate)
        }
        #endif
        if active, let status = (response as? HTTPURLResponse)?.statusCode, (300..<400).contains(status) {
            fail(code: "invalid_response")
            completionHandler(.cancel)
        } else {
            completionHandler(active ? .allow : .cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        #if CHICKINFRY_CONFORMANCE
        observation?.observe("read", bytes: data.count)
        #endif
        let reception = lock.withLock { () -> Bool? in
            guard !finished else { return nil }
            guard data.count <= 1024 * 1024 - body.count else { return true }
            body.append(data)
            #if CHICKINFRY_CONFORMANCE
            observation?.account(data.count)
            #endif
            return false
        }
        guard let overflow = reception else { return }
        #if CHICKINFRY_CONFORMANCE
        observation?.inspect(Conformance.Buffers(
            exchange: observationID, response: { 0 }, accumulated: { [weak self] in
                guard let self else { return 0 }
                return self.lock.withLock { self.body.count }
            }, holdOwner: { [weak self] in
                guard let self else { return nil }
                return { withExtendedLifetime(self) {} }
            }))
        if overflow { observation?.observe("limit", immediate: true) }
        #endif
        if overflow { fail(code: "response_too_large") }
    }

    #if CHICKINFRY_CONFORMANCE
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        if bytesSent > 0 {
            observation?.transmitted()
            refreshTransmission?.finish(true)
        }
    }
    #endif

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // URLSession can accumulate the declined body before delivering data callbacks.
        lock.withLock {
            if !finished {
                status = response.statusCode
                #if CHICKINFRY_CONFORMANCE
                immediate = true
                #endif
            }
        }
        #if CHICKINFRY_CONFORMANCE
        observation?.observe("headers", status: response.statusCode, immediate: true)
        #endif
        fail(code: "invalid_response")
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        #if CHICKINFRY_CONFORMANCE
        if (error as? URLError)?.code == .cancelled {
            observation?.observe("cancel-observed", immediate: observationIsImmediate)
        }
        observation?.observe("reader-closed", immediate: observationIsImmediate)
        #endif
        if let error {
            let urlError = error as? URLError
            let code = urlError?.code == .timedOut ? "timeout"
                : urlError?.code == .cancelled ? "cancelled" : "transport_error"
            finish(code: code, cancelTask: false)
        } else {
            finish(code: nil)
        }
    }
}
