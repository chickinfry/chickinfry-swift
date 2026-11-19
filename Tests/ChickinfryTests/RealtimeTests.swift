import XCTest
@testable import Chickinfry

final class RealtimeTests: XCTestCase {
    func testTicketIsRestrictedToCanonicalProjectAddress() throws {
        let base = "wss://10000000-0000-4000-8000-000000000001.chickinfry.app/realtime"
        XCTAssertEqual(try realtimeEndpoint(base), base)
        for invalid in [base + "?ticket=other", base.replacingOccurrences(of: "wss:", with: "ws:"), "ws://127.0.0.1/realtime"] {
            XCTAssertThrowsError(try realtimeEndpoint(invalid))
        }
    }
}
