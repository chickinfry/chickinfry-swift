import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The JSON operation boundary used by generated clients.
public struct ClientTransport: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let origin: String
    private let timeout: TimeInterval
    private let bearer: String?

    // Limit reflection output because private properties are included by default.
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
    }

    private init(origin: String, timeout: TimeInterval, bearer: String) {
        self.origin = origin
        self.timeout = timeout
        self.bearer = bearer
    }

    /// Returns an authenticated copy; the original transport remains unchanged.
    public func withBearer(_ token: String) throws -> Self {
        guard token.utf8.count == 43,
              token.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0)
                  || (48...57).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw OperationError(code: "invalid_token", status: nil)
        }
        return Self(origin: origin, timeout: timeout, bearer: token)
    }

    public func invoke<Input: Encodable & Sendable, Output: Decodable & Sendable>(
        _ operation: String, input: Input, as outputType: Output.Type = Output.self
    ) async throws -> Output {
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
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }

        let receiver = ResponseReceiver()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration, delegate: receiver, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        let response = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                receiver.start(task: task, timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            receiver.fail(code: "cancelled")
        }
        guard let status = response.status else {
            throw OperationError(code: "invalid_response", status: nil)
        }
        // Reject other encodings containing NUL and validate raw UTF-8 without Foundation's recovery behavior.
        guard !response.body.contains(0),
              (response.body + Data([0])).withUnsafeBytes({
                  String(validatingCString: $0.bindMemory(to: CChar.self).baseAddress!) != nil
              }) else {
            throw OperationError(code: "invalid_response", status: status)
        }
        if !(200..<300).contains(status) {
            let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: response.body)
            let code = envelope?.error
            let valid = code?.range(of: "\\A[a-z_]+\\z", options: .regularExpression) != nil
            throw OperationError(code: valid ? code! : "invalid_response", status: status)
        }
        do {
            guard (try JSONSerialization.jsonObject(with: response.body)) is [String: Any] else {
                throw OperationError(code: "invalid_response", status: status)
            }
            return try JSONDecoder().decode(outputType, from: response.body)
        } catch {
            throw OperationError(code: "invalid_response", status: status)
        }
    }

    private static func validateOrigin(_ raw: String) throws -> String {
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

private struct ErrorEnvelope: Decodable { let error: String }
private struct ReceivedResponse: Sendable { let body: Data; let status: Int? }

// All delegate, cancellation, and deadline state is protected by the same lock.
private final class ResponseReceiver: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var body = Data()
    private var status: Int?
    private var task: URLSessionDataTask?
    private var deadline: Task<Void, Never>?
    private var continuation: CheckedContinuation<ReceivedResponse, any Error>?
    private var finished = false

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
            task.resume()
            return false
        }
        if alreadyCancelled {
            task.cancel()
            continuation.resume(throwing: OperationError(code: "cancelled", status: nil))
        }
    }

    func fail(code: String) { finish(code: code) }

    private func finish(code: String?) {
        let completion = lock.withLock { () -> (
            CheckedContinuation<ReceivedResponse, any Error>?, URLSessionDataTask?, Task<Void, Never>?,
            ReceivedResponse
        )? in
            guard !finished else { return nil }
            finished = true
            if status == nil { status = (task?.response as? HTTPURLResponse)?.statusCode }
            let result = (continuation, task, deadline, ReceivedResponse(body: body, status: status))
            continuation = nil
            task = nil
            deadline = nil
            body = Data()
            return result
        }
        guard let (continuation, task, deadline, response) = completion else { return }
        deadline?.cancel()
        if let code {
            task?.cancel()
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
            return true
        }
        completionHandler(active ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overflow = lock.withLock {
            guard !finished else { return false }
            guard data.count <= 1024 * 1024 - body.count else { return true }
            body.append(data)
            return false
        }
        if overflow { fail(code: "response_too_large") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // FoundationNetworking buffers 301...308 bodies before this callback, bypassing the data limit.
        lock.withLock { if !finished { status = response.statusCode } }
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error {
            let urlError = error as? URLError
            let code = urlError?.code == .timedOut ? "timeout"
                : urlError?.code == .cancelled ? "cancelled" : "transport_error"
            fail(code: code)
        } else {
            finish(code: nil)
        }
    }
}
