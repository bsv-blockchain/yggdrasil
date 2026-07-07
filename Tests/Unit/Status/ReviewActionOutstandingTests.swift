import XCTest
@testable import Yggdrasil

/// The GitHub-derived "outstanding review action for me" signal that drives the
/// amber REVIEW pill. Independent of whether the tab was opened.
final class ReviewActionOutstandingTests: XCTestCase {
    private func status(
        latestReview: String?,
        reviewedHead: String?,
        head: String?,
        unresolvedAwaiting: Int = 0
    ) -> GitHubStatus {
        GitHubStatus(
            taskID: 1, ciState: nil, ciURL: nil, mergeable: nil, mergeableState: nil,
            reviewState: nil, unreadCommentsCount: 0, lastSeenCommentID: nil,
            fetchedAt: Date(timeIntervalSince1970: 0),
            commentsReviewsTotal: 0, commitsTotal: 0, headSHA: head,
            seenCommentsReviewsTotal: nil, seenCommitsTotal: nil, seenHeadSHA: nil,
            viewerLatestReviewState: latestReview,
            viewerReviewedHeadSHA: reviewedHead,
            unresolvedThreadsAwaitingViewer: unresolvedAwaiting
        )
    }

    func testNeverReviewedIsNotOutstanding() {
        // Nothing is directed at you yet → blue, not amber.
        let s = status(latestReview: nil, reviewedHead: nil, head: "abc")
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testReviewedCurrentHeadIsNotOutstanding() {
        // Any review type covering the current head → ball's in author's court.
        for state in ["APPROVED", "COMMENTED", "CHANGES_REQUESTED"] {
            let s = status(latestReview: state, reviewedHead: "abc", head: "abc")
            XCTAssertFalse(s.reviewActionOutstanding, "\(state) on current head → not outstanding")
        }
    }

    func testReviewedThenNewCommitsIsOutstanding() {
        // You reviewed an older head; author pushed since → re-review is due.
        for state in ["APPROVED", "COMMENTED", "CHANGES_REQUESTED"] {
            let s = status(latestReview: state, reviewedHead: "old", head: "new")
            XCTAssertTrue(s.reviewActionOutstanding, "\(state) + new commits → outstanding")
        }
    }

    func testThreadAwaitingIsOutstanding() {
        // A reply after yours in a thread you're in — even if you approved.
        let s = status(latestReview: "APPROVED", reviewedHead: "abc", head: "abc", unresolvedAwaiting: 1)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testNeverReviewedButThreadAwaitingIsOutstanding() {
        // You commented in a thread (no formal review) and someone replied.
        let s = status(latestReview: nil, reviewedHead: nil, head: "abc", unresolvedAwaiting: 1)
        XCTAssertTrue(s.reviewActionOutstanding)
    }
}
