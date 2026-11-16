import XCTest
@testable import Yggdrasil

/// The transcript view follows new output until the reader scrolls up, and
/// keeps what they're reading in place while it grows.
final class SubagentTranscriptFollowTests: XCTestCase {
    func testFollowsUntilTheReaderScrollsUpAndAgainOnceTheyReturn() {
        var follow = TranscriptFollow()
        XCTAssertTrue(follow.following, "a transcript opens at its end")
        follow.userScrolled(distanceFromBottom: 600, movedUp: true)
        XCTAssertFalse(follow.following)
        follow.userScrolled(distanceFromBottom: 300, movedUp: false)
        XCTAssertFalse(follow.following, "heading back, not there yet")
        follow.userScrolled(distanceFromBottom: 10, movedUp: false)
        XCTAssertTrue(follow.following, "back at the end, within a little slack")
        follow.userScrolled(distanceFromBottom: 600, movedUp: true)
        follow.reset()
        XCTAssertTrue(follow.following, "another subagent opens at its end")
    }

    func testAnyScrollUpStopsFollowingEvenANudge() {
        // With rows arriving fast, a few points up would otherwise still be
        // "at the end" and get pulled straight back.
        var follow = TranscriptFollow()
        follow.userScrolled(distanceFromBottom: 8, movedUp: true)
        XCTAssertFalse(follow.following)
    }

    private func item(_ id: String) -> SubagentTranscriptItem {
        SubagentTranscriptItem(id: id, entry: .text(id))
    }

    func testNewRowsAreAddedAfterTheShownOnes() {
        // Past 1 MB the parsed window slides: "a" fell off its front. It
        // stays on screen, so nothing above the reader moves.
        let merged = SubagentTranscriptLoader.merged(
            [item("a"), item("b"), item("c")], with: [item("b"), item("c"), item("d")]
        )
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c", "d"])
    }

    func testNothingNewKeepsWhatsShown() {
        let shown = [item("a"), item("b")]
        XCTAssertEqual(SubagentTranscriptLoader.merged(shown, with: [item("b")]), shown)
    }

    func testATranscriptThatNoLongerHasTheLastShownRowReplacesIt() {
        // Rewritten or replaced: there's nothing to continue from.
        XCTAssertEqual(SubagentTranscriptLoader.merged([item("a"), item("b")], with: [item("x")]).map(\.id), ["x"])
        XCTAssertEqual(SubagentTranscriptLoader.merged([], with: [item("x")]).map(\.id), ["x"])
    }
}
