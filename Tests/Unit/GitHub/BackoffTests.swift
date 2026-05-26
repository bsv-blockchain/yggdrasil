@testable import Loom
import XCTest

final class BackoffTests: XCTestCase {
    func testFirstAttemptIsOneSecond() {
        XCTAssertEqual(Backoff.delay(forAttempt: 1), 1)
    }

    func testDoublesEachAttempt() {
        XCTAssertEqual(Backoff.delay(forAttempt: 2), 2)
        XCTAssertEqual(Backoff.delay(forAttempt: 3), 4)
        XCTAssertEqual(Backoff.delay(forAttempt: 4), 8)
        XCTAssertEqual(Backoff.delay(forAttempt: 5), 16)
        XCTAssertEqual(Backoff.delay(forAttempt: 9), 256)
    }

    func testCapsAt5Minutes() {
        // 2^9 = 512 > 300; should cap at 300.
        XCTAssertEqual(Backoff.delay(forAttempt: 10), 300)
        XCTAssertEqual(Backoff.delay(forAttempt: 50), 300)
    }

    func testZeroOrNegativeAttemptIsClampedToOne() {
        XCTAssertEqual(Backoff.delay(forAttempt: 0), 1)
        XCTAssertEqual(Backoff.delay(forAttempt: -3), 1)
    }
}
