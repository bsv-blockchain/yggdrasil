import Foundation
import XCTest
@testable import Yggdrasil

/// The predicate behind the sidebar's "Needs me" filter. It must match what the
/// eye sees on the row — an amber REVIEW/REPLY pill, a Claude session stopped
/// for input, or red CI on a PR the viewer wrote. Informational signals (unread
/// comments, a dirty worktree, a running agent) must never qualify, or the
/// filter matches every tab and stops being a filter.
final class NeedsAttentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func status(
        claude: ClaudeState = .idle,
        dirty: Bool = false,
        ciState: String? = nil,
        unread: Int = 0,
        reviewActivity: Bool = false,
        threadsAwaitingReply: Int = 0,
        viewerDidAuthorPR: Bool = false
    ) -> TabStatus {
        TabStatus.aggregate(
            claude: claude,
            git: GitState(dirty: dirty, remote: .noRemote),
            github: .init(
                ciState: ciState, unread: unread, hasActivity: reviewActivity,
                threadsAwaitingReply: threadsAwaitingReply,
                viewerDidAuthorPR: viewerDidAuthorPR
            )
        )
    }

    private func needsAttention(_ branch: String, _ status: TabStatus?) -> Bool {
        TabRowViewModel.needsAttention(branchName: branch, status: status)
    }

    // MARK: - Nothing to go on

    func testNoLiveStatusDoesNotNeedAttention() {
        XCTAssertFalse(needsAttention("review-pr-655", nil))
    }

    func testQuietTabDoesNotNeedAttention() {
        XCTAssertFalse(needsAttention("review-pr-655", status()))
    }

    // MARK: - The amber pills

    func testReviewTabWithOutstandingActionNeedsAttention() {
        XCTAssertTrue(needsAttention("review-pr-655", status(reviewActivity: true)))
    }

    func testAuthoredPRTabWithThreadsAwaitingReplyNeedsAttention() {
        XCTAssertTrue(needsAttention("claude-pr-655", status(threadsAwaitingReply: 4)))
    }

    /// No REVIEW pill renders off a review branch, so the filter must not claim
    /// one — the row would show up with no visible reason.
    func testNonReviewTabWithReviewActivityDoesNotNeedAttention() {
        XCTAssertFalse(needsAttention("feat/foo", status(reviewActivity: true)))
    }

    /// Mirror case: the REPLY pill is suppressed on review tabs.
    func testReviewTabWithThreadsAwaitingReplyDoesNotNeedAttention() {
        XCTAssertFalse(needsAttention("review-pr-655", status(threadsAwaitingReply: 4)))
    }

    // MARK: - Claude blocked on me

    func testClaudeAwaitingInputNeedsAttention() {
        XCTAssertTrue(needsAttention("feat/foo", status(claude: .awaitingInput)))
    }

    func testClaudeErroredNeedsAttention() {
        XCTAssertTrue(needsAttention("feat/foo", status(claude: .errored)))
    }

    /// A working agent is the machine's move, not mine.
    func testClaudeRunningDoesNotNeedAttention() {
        XCTAssertFalse(needsAttention("feat/foo", status(claude: .running)))
    }

    // MARK: - Informational signals stay out

    func testUnreadCommentsDoNotNeedAttention() {
        XCTAssertFalse(needsAttention("review-pr-655", status(unread: 7)))
    }

    func testDirtyWorktreeDoesNotNeedAttention() {
        XCTAssertFalse(needsAttention("feat/foo", status(dirty: true)))
    }

    // MARK: - CI, gated on authorship

    func testRedCIOnMyOwnPRNeedsAttention() {
        XCTAssertTrue(
            needsAttention("claude-pr-655", status(ciState: "FAILURE", viewerDidAuthorPR: true))
        )
    }

    /// Red CI on someone else's PR is their problem, not an action for me.
    func testRedCIOnSomeoneElsesPRDoesNotNeedAttention() {
        XCTAssertFalse(
            needsAttention("review-pr-655", status(ciState: "FAILURE", viewerDidAuthorPR: false))
        )
    }
}
