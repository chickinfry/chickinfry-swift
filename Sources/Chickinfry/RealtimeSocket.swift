import Foundation
#if os(Linux) && ClientTransport
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import NIOWebSocket
#endif

struct RealtimeSocket: Sendable {
    let send: @Sendable (String) async throws -> Void
    let close: @Sendable () -> Void
}

#if os(Linux) && ClientTransport
private let realtimeEventLoops = MultiThreadedEventLoopGroup.singleton

func withRealtimeSocket(
    _ address: URL,
    opened: @Sendable (RealtimeSocket) async -> Bool,
    received: @Sendable (String) async -> Bool
) async throws {
    guard let host = address.host else { throw ClientError(code: "internal", status: nil) }
    let tls = address.scheme == "wss"
    let port = address.port ?? (tls ? 443 : 80)
    let requestPath = address.path + (address.query.map { "?" + $0 } ?? "")
    let deadline = CallDeadline(timeout: 10)
    let context = tls ? try NIOSSLContext(configuration: .makeClientConfiguration()) : nil

    typealias WSChannel = NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    typealias Negotiated = EventLoopFuture<WSChannel>
    let (channel, negotiated): (any Channel, Negotiated) = try await ClientBootstrap(group: realtimeEventLoops)
        .connectTimeout(.seconds(10))
        .connect(host: host, port: port) { channel in
            channel.eventLoop.makeCompletedFuture {
                if let context {
                    let tlsHandler = try NIOSSLClientHandler(context: context, serverHostname: host)
                    try channel.pipeline.syncOperations.addHandler(tlsHandler)
                }
                let upgrade = NIOTypedWebSocketClientUpgrader<WSChannel>(
                    maxFrameSize: realtimeFrameSize,
                    upgradePipelineHandler: { channel, _ in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(NIOWebSocketFrameAggregator(
                                minNonFinalFragmentSize: 1, maxAccumulatedFrameCount: realtimeFrameSize,
                                maxAccumulatedFrameSize: realtimeFrameSize
                            ))
                            return try WSChannel(wrappingChannelSynchronously: channel)
                        }
                    }
                )
                let hostHeader = address.port.map { "\(host):\($0)" } ?? host
                let request = HTTPRequestHead(version: .http1_1, method: .GET, uri: requestPath,
                                              headers: HTTPHeaders([("Host", hostHeader)]))
                let configuration = NIOTypedHTTPClientUpgradeConfiguration(
                    upgradeRequestHead: request, upgraders: [upgrade],
                    notUpgradingCompletionHandler: { channel in
                        channel.eventLoop.makeFailedFuture(ClientError(code: "unavailable", status: nil))
                    }
                )
                let negotiated = try channel.pipeline.syncOperations.configureUpgradableHTTPClientPipeline(
                    configuration: .init(upgradeConfiguration: configuration)
                )
                return (channel, negotiated)
            }
        }
    defer { channel.close(promise: nil) }
    let upgraded = try await deadline.wait { try await negotiated.getAbandoningOnCancel() }
    try await upgraded.executeThenClose { inbound, outbound in
        let socket = RealtimeSocket(send: { text in
            try await outbound.write(WebSocketFrame(fin: true, opcode: .text,
                maskKey: .random(), data: ByteBuffer(string: text)))
        }, close: { channel.close(promise: nil) })
        guard await opened(socket) else { return }
        for try await frame in inbound {
            switch frame.opcode {
            case .text:
                guard let text = String(bytes: frame.unmaskedData.readableBytesView, encoding: .utf8) else {
                    throw ClientError(code: "internal", status: nil)
                }
                if await !received(text) { return }
            case .connectionClose:
                try? await outbound.write(WebSocketFrame(fin: true, opcode: .connectionClose,
                    maskKey: .random(), data: frame.unmaskedData))
                return
            case .ping:
                try await outbound.write(WebSocketFrame(fin: true, opcode: .pong,
                    maskKey: .random(), data: frame.unmaskedData))
            case .pong:
                continue
            default:
                throw ClientError(code: "internal", status: nil)
            }
        }
    }
}
#else
private final class UpgradeDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

func withRealtimeSocket(
    _ address: URL,
    opened: @Sendable (RealtimeSocket) async -> Bool,
    received: @escaping @Sendable (String) async -> Bool
) async throws {
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil
    config.urlCredentialStorage = nil
    config.timeoutIntervalForRequest = 10
    let session = URLSession(configuration: config, delegate: UpgradeDelegate(), delegateQueue: nil)
    let task = session.webSocketTask(with: address)
    task.maximumMessageSize = realtimeFrameSize
    task.resume()
    let (done, completion) = AsyncThrowingStream<Void, any Error>.makeStream()
    let socket = RealtimeSocket(send: { try await task.send(.string($0)) }, close: {
        completion.finish()
        task.cancel()
        session.invalidateAndCancel()
    })
    defer { socket.close() }
    guard await opened(socket) else { return }
    let reader = Task {
        do {
            while !Task.isCancelled {
                guard case .string(let text) = try await task.receive() else {
                    throw ClientError(code: "internal", status: nil)
                }
                if await !received(text) { break }
            }
            completion.finish()
        } catch {
            completion.finish(throwing: error)
        }
    }
    defer { reader.cancel() }
    // Release the connection loop when the SDK closes this generation.
    for try await _ in done {}
}
#endif
