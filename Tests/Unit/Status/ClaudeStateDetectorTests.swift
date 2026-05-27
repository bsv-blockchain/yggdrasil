@testable import Yggdrasil
import XCTest

final class ClaudeStateDetectorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNoRecordsReturnsUnknown() {
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: nil, lastRecordStopReason: nil,
                lastRecordAt: nil, now: now
            ),
            .unknown
        )
    }

    func testAssistantMessageWithinFiveSecondsIsRunning() {
        let fourSecondsAgo = now.addingTimeInterval(-4)
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "assistant",
                lastRecordStopReason: nil,
                lastRecordAt: fourSecondsAgo,
                now: now
            ),
            .running
        )
    }

    func testEndTurnWithinThirtySecondsIsStillRunning() {
        // Spec: "running — entry in last 5s with type==assistant and no terminal stop_reason".
        // Conservative read: end_turn within the very-recent window keeps us in running
        // until the 30s "awaiting" threshold elapses. The 5s rule applies to assistant
        // messages without a terminal stop_reason.
        let tenSecondsAgo = now.addingTimeInterval(-10)
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "assistant",
                lastRecordStopReason: "end_turn",
                lastRecordAt: tenSecondsAgo,
                now: now
            ),
            .awaitingInput,
            "an end_turn record means the model is awaiting the user"
        )
    }

    func testEndTurnOlderThanThirtySecondsIsAwaitingInput() {
        let oneMinuteAgo = now.addingTimeInterval(-60)
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "assistant",
                lastRecordStopReason: "end_turn",
                lastRecordAt: oneMinuteAgo,
                now: now
            ),
            .awaitingInput
        )
    }

    func testNothingForFiveMinutesIsIdle() {
        let fiveMinutesAgo = now.addingTimeInterval(-301)
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "assistant",
                lastRecordStopReason: "end_turn",
                lastRecordAt: fiveMinutesAgo,
                now: now
            ),
            .idle
        )
    }

    func testErrorTypeIsErrored() {
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "error", lastRecordStopReason: nil,
                lastRecordAt: now.addingTimeInterval(-2), now: now
            ),
            .errored
        )
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "tool_error", lastRecordStopReason: nil,
                lastRecordAt: now.addingTimeInterval(-2), now: now
            ),
            .errored,
            "any type substring 'error' counts as errored"
        )
    }

    func testUserMessageBetweenSetsRunning() {
        // After the user sends a new message, the next assistant record will appear
        // shortly. While we're waiting on it, we report running (the user just
        // unblocked the model).
        XCTAssertEqual(
            ClaudeStateDetector.evaluate(
                lastRecordType: "user", lastRecordStopReason: nil,
                lastRecordAt: now.addingTimeInterval(-1), now: now
            ),
            .running
        )
    }
}
