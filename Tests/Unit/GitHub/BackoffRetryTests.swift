import XCTest
@testable import Yggdrasil

/// Capture the durations passed to the injected sleep closure so tests can verify
/// the backoff schedule was followed.
actor SleepRecorder {
    private(set) var recorded: [Duration] = []

    func sleep(_ duration: Duration) {
        recorded.append(duration)
    }
}

final class BackoffRetryTests: XCTestCase {
    func testSucceedsOnFirstAttemptWithoutSleeping() async throws {
        let recorder = SleepRecorder()
        let result = try await BackoffRetry.attempt(
            maxAttempts: 5,
            sleep: { duration in await recorder.sleep(duration) },
            operation: { "ok" }
        )
        XCTAssertEqual(result, "ok")
        let slept = await recorder.recorded
        XCTAssertTrue(slept.isEmpty, "no sleeps when first attempt succeeds")
    }

    func testRetriesUntilSuccessFollowingExpectedBackoffSchedule() async throws {
        let recorder = SleepRecorder()
        var attemptCount = 0
        let result = try await BackoffRetry.attempt(
            maxAttempts: 5,
            sleep: { duration in await recorder.sleep(duration) },
            operation: {
                attemptCount += 1
                if attemptCount < 3 {
                    throw NSError(domain: "net", code: -1)
                }
                return attemptCount
            }
        )
        XCTAssertEqual(result, 3, "succeeded on third attempt")
        let slept = await recorder.recorded
        // Backoff between attempts: 1s after attempt 1, 2s after attempt 2. No
        // sleep after the successful attempt.
        XCTAssertEqual(slept, [.seconds(1), .seconds(2)])
    }

    func testGivesUpAfterMaxAttemptsAndRethrowsLastError() async {
        let recorder = SleepRecorder()
        var attemptCount = 0

        do {
            _ = try await BackoffRetry.attempt(
                maxAttempts: 3,
                sleep: { duration in await recorder.sleep(duration) },
                operation: {
                    attemptCount += 1
                    throw NSError(domain: "net", code: attemptCount)
                }
            )
            XCTFail("expected to throw")
        } catch let err as NSError {
            XCTAssertEqual(err.code, 3, "last error is rethrown")
        }

        let slept = await recorder.recorded
        // Sleep happens AFTER each failed attempt except the last → 2 sleeps for 3 attempts.
        XCTAssertEqual(slept, [.seconds(1), .seconds(2)])
        XCTAssertEqual(attemptCount, 3)
    }
}
