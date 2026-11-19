#if canImport(Darwin)
// The SDK does not support Linux FoundationNetworking, which buffers 301 bodies and can crash on the redirect callback.
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
                    let start = ContinuousClock.now
                    var failure: ClientError?
                    do {
                        let _: Empty = try await transport.invoke("probe.echo", input: Empty())
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
#endif
