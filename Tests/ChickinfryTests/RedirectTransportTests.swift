import Foundation
import Testing
@testable import Chickinfry

@Test func largeRedirectClosesDuringPrefixWithoutBodySizeGrowth() async throws {
    for status in [301, 302, 303, 307, 308] {
        for chunked in [false, true] {
            var sentBySize: [Int] = []
            for size in [8, 64] {
                for attempt in 0..<3 {
                    let peer = try LoopbackServer([.redirectStream(status, chunked, size * 1024 * 1024)])
                    let transport = try HTTPTransport(origin: peer.origin, timeout: 3)
                    let invoke: @Sendable () async throws -> Empty = {
                        try await transport.invoke("probe.echo", input: Empty())
                    }
                    #if os(Linux)
                    let storage = RedirectBufferProbe()
                    let send: @Sendable () async throws -> Empty = {
                        try await HTTPTransport.$inspectLinuxResponseBuffer.withValue({ storage.record($0) }) {
                            try await invoke()
                        }
                    }
                    #else
                    let send = invoke
                    #endif
                    let start = ContinuousClock.now
                    var failure: ClientError?
                    do {
                        _ = try await send()
                        Issue.record("A redirect must fail")
                    } catch let error as ClientError { failure = error }
                    let elapsed = start.duration(to: .now)
                    await peer.log.waitForCompletions(1)
                    let completion = try #require(await peer.log.completions.first)
                    await peer.stop()
                    print("REDIRECT status=\(status) chunked=\(chunked) mib=\(size) attempt=\(attempt) sent=\(completion.sent) elapsed=\(elapsed) closed=\(completion.disconnected)")
                    #expect(failure?.status == status)
                    #expect(failure?.code == "internal")
                    // A stalled redirect reaches the three-second deadline; one second leaves hundreds of scheduling turns.
                    try #require(elapsed < .seconds(1))
                    #expect(completion.disconnected)
                    #expect(completion.sent < 1024 * 1024 + 1)
                    #if os(Linux)
                    #expect(storage.maximum == 0)
                    print("REDIRECT_BUFFER status=\(status) chunked=\(chunked) mib=\(size) retained=\(storage.maximum ?? -1)")
                    #endif
                    sentBySize.append(completion.sent)
                }
            }
            let small = sentBySize.prefix(3).max() ?? 0
            let large = sentBySize.suffix(3).max() ?? 0
            // Socket scheduling may add a few chunks; an eightfold body increase must not scale retention.
            #expect(large <= max(64 * 1024, small + 64 * 1024))
        }
    }
}

#if os(Linux)
private final class RedirectBufferProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var peak: Int?

    var maximum: Int? { lock.withLock { peak } }

    func record(_ count: Int) {
        lock.withLock { peak = max(peak ?? 0, count) }
    }
}
#endif
