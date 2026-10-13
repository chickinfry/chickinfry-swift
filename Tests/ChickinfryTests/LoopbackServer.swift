import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum PeerResponse: Sendable {
    case reply(Int, Data, [String: String] = [:])
    case stream(Int)
    case stall(Bool)
    case disconnect
    case truncated
}

struct PeerRequest: Sendable {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct PeerCompletion: Sendable {
    let sent: Int
    let disconnected: Bool
}

actor PeerLog {
    private let responses: [PeerResponse]
    private(set) var requests: [PeerRequest] = []
    private(set) var completions: [PeerCompletion] = []
    private(set) var stopped = false
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(_ responses: [PeerResponse]) { self.responses = responses }

    func receive(_ request: PeerRequest) -> PeerResponse {
        let index = requests.count
        requests.append(request)
        let ready = requestWaiters.filter { $0.0 <= requests.count }
        requestWaiters.removeAll { $0.0 <= requests.count }
        for (_, continuation) in ready { continuation.resume() }
        return index < responses.count ? responses[index] : .reply(200, Data("{}".utf8))
    }

    func complete(sent: Int, disconnected: Bool) {
        completions.append(PeerCompletion(sent: sent, disconnected: disconnected))
        let ready = waiters.filter { $0.0 <= completions.count }
        waiters.removeAll { $0.0 <= completions.count }
        for (_, continuation) in ready { continuation.resume() }
    }

    func waitForCompletions(_ count: Int) async {
        if completions.count >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func waitForRequests(_ count: Int) async {
        if requests.count >= count { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
    }

    func stop() { stopped = true }
}

final class LoopbackServer: Sendable {
    let origin: String
    let log: PeerLog
    private let listener: Int32
    private let port: UInt16
    private let worker: Task<Void, Never>

    init(_ responses: [PeerResponse] = []) throws {
        #if canImport(Darwin)
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let descriptor = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard descriptor >= 0 else { throw PeerFailure.socket }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 16) == 0 else {
            close(descriptor)
            throw PeerFailure.socket
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(descriptor); throw PeerFailure.socket }
        origin = "http://127.0.0.1:\(UInt16(bigEndian: address.sin_port))"
        port = address.sin_port
        listener = descriptor
        let log = PeerLog(responses)
        self.log = log
        worker = Task.detached {
            while true {
                let client: Int32 = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(returning: accept(descriptor, nil, nil))
                    }
                }
                guard client >= 0 else { return }
                if await log.stopped { close(client); return }
                #if canImport(Darwin)
                var noSignal: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                               socklen_t(MemoryLayout<Int32>.size))
                #endif
                var receiveTimeout = timeval(tv_sec: 5, tv_usec: 0)
                _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout,
                               socklen_t(MemoryLayout<timeval>.size))
                let request = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        continuation.resume(returning: Self.readRequest(client))
                    }
                }
                if let request {
                    let response = await log.receive(request)
                    await Self.respond(response, client: client, log: log)
                }
                close(client)
            }
        }
    }

    func stop() async {
        await log.stop()
        // A wake connection releases accept on hosts where shutdown of a listener does not.
        #if canImport(Darwin)
        let wake = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let wake = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(wake, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(wake)
        await worker.value
        close(listener)
    }

    private static func readRequest(_ client: Int32) -> PeerRequest? {
        var bytes = Data()
        let delimiter = Data("\r\n\r\n".utf8)
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while bytes.range(of: delimiter) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0, bytes.count < 64 * 1024 else { return nil }
            bytes.append(contentsOf: buffer.prefix(count))
        }
        guard let range = bytes.range(of: delimiter),
              let header = String(data: bytes[..<range.lowerBound], encoding: .utf8) else { return nil }
        let lines = header.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            headers[String(line[..<colon]).lowercased()] = line[line.index(after: colon)...]
                .trimmingCharacters(in: .whitespaces)
        }
        guard let size = Int(headers["content-length"] ?? "0"), (0...5 * 1024 * 1024).contains(size) else {
            return nil
        }
        var body = Data(bytes[range.upperBound...])
        while body.count < size {
            let count = recv(client, &buffer, min(buffer.count, size - body.count), 0)
            guard count > 0 else { return nil }
            body.append(contentsOf: buffer.prefix(count))
        }
        return PeerRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: body)
    }

    private static func write(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if canImport(Darwin)
                let count = send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #else
                let count = send(client, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func respond(_ response: PeerResponse, client: Int32, log: PeerLog) async {
        var sent = 0
        var disconnected = false
        switch response {
        case let .reply(status, body, headers):
            let extras = headers.map { "\($0.key): \($0.value)\r\n" }.sorted().joined()
            let header = "HTTP/1.1 \(status) Test\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\(extras)\r\n"
            disconnected = !write(Data(header.utf8), to: client) || !write(body, to: client)
            sent = body.count
        case let .stream(size):
            // No Content-Length: the client must enforce the limit while receiving real chunks.
            disconnected = !write(Data("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".utf8), to: client)
            let chunk = Data(repeating: 32, count: 16 * 1024)
            while sent < size, !disconnected {
                let next = min(chunk.count, size - sent)
                if write(Data(chunk.prefix(next)), to: client) { sent += next }
                else { disconnected = true }
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
        case let .stall(headers):
            if headers {
                _ = write(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n".utf8), to: client)
                let byte = Data(repeating: 32, count: 16 * 1024)
                while write(byte, to: client) {
                    sent += byte.count
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                disconnected = true
            } else {
                disconnected = await withCheckedContinuation { continuation in
                    DispatchQueue.global().async {
                        var byte: UInt8 = 0
                        continuation.resume(returning: recv(client, &byte, 1, 0) == 0)
                    }
                }
            }
        case .disconnect:
            disconnected = true
        case .truncated:
            _ = write(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 999\r\nConnection: close\r\n\r\n{".utf8), to: client)
            sent = 1
        }
        await log.complete(sent: sent, disconnected: disconnected)
    }
}

private enum PeerFailure: Error { case socket }
