import XCTest
@testable import Yggdrasil

/// Maps what the transcript says into the state the sidebar renders.
///
/// The rule that matters: only an explicit pending question (and an API error)
/// is "needs you". A finished turn is the resting state of nearly every open
/// tab — 21 of 27 live tabs sit there — so treating it as a demand would make
/// the "Needs me" filter match almost everything and mean nothing.
final class ClaudeStateDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func state(_ activity: AgentActivity, ageSeconds: TimeInterval = 0) -> ClaudeState {
        ClaudeStateDetector.evaluate(
            activity: AgentActivitySample(activity: activity, timestamp: now.addingTimeInterval(-ageSeconds)),
            now: now
        )
    }

    func testNoTranscriptIsUnknown() {
        XCTAssertEqual(ClaudeStateDetector.evaluate(activity: nil, now: now), .unknown)
    }

    // MARK: - The states that demand attention

    func testPendingQuestionIsAwaitingInput() {
        XCTAssertEqual(state(.awaitingAnswer), .awaitingInput)
    }

    /// Latched deliberately: a question doesn't stop being unanswered because
    /// time passed. Real transcripts show gaps of 5+ minutes before an answer,
    /// so any decay window would drop the row exactly when it still matters.
    func testPendingQuestionDoesNotDecayToIdle() {
        XCTAssertEqual(state(.awaitingAnswer, ageSeconds: 60 * 60 * 24), .awaitingInput)
    }

    func testAPIErrorIsErrored() {
        XCTAssertEqual(state(.errored), .errored)
    }

    func testErrorDoesNotDecayEither() {
        XCTAssertEqual(state(.errored, ageSeconds: 60 * 60), .errored)
    }

    // MARK: - The states that don't

    /// The decision this encodes: a finished turn is idle, not amber.
    func testFinishedTurnIsIdleNotAwaiting() {
        XCTAssertEqual(state(.turnEnded), .idle)
        XCTAssertEqual(state(.turnEnded, ageSeconds: 60 * 60), .idle)
    }

    func testRecentWorkIsRunning() {
        XCTAssertEqual(state(.working), .running)
        XCTAssertEqual(state(.working, ageSeconds: 60), .running)
    }

    /// A tool call can run for minutes without writing a record, so the window
    /// is the idle threshold rather than something tight.
    func testWorkJustInsideTheIdleThresholdIsStillRunning() {
        XCTAssertEqual(state(.working, ageSeconds: ClaudeStateDetector.idleThreshold - 1), .running)
    }

    func testWorkOlderThanTheIdleThresholdIsIdle() {
        XCTAssertEqual(state(.working, ageSeconds: ClaudeStateDetector.idleThreshold + 1), .idle)
    }

    /// Clock skew: a record stamped in the future gives a negative age, which
    /// must not read as stale.
    func testFutureTimestampIsNotTreatedAsIdle() {
        XCTAssertEqual(state(.working, ageSeconds: -30), .running)
    }
}
