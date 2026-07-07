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

    func testNotReviewedIsOutstanding() {
        let s = status(latestReview: nil, reviewedHead: nil, head: "abc")
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testApprovedCurrentHeadIsDone() {
        let s = status(latestReview: "APPROVED", reviewedHead: "abc", head: "abc")
        XCTAssertTrue(s.reviewCoversCurrentHead)
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testApprovedButNewCommitsIsOutstanding() {
        // Approval covered an older head; author pushed since → re-review.
        let s = status(latestReview: "APPROVED", reviewedHead: "old", head: "new")
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testCommentedOnCurrentHeadIsDone() {
        // Posting a Comment review is your own action — the ball is now in the
        // author's court, so it must NOT flag as your move. (Regression: this
        // used to turn amber because it wasn't "APPROVED".)
        let s = status(latestReview: "COMMENTED", reviewedHead: "abc", head: "abc")
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testChangesRequestedOnCurrentHeadIsDone() {
        // You've acted (requested changes) on the current head — waiting on the
        // author, not your move.
        let s = status(latestReview: "CHANGES_REQUESTED", reviewedHead: "abc", head: "abc")
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testReviewedThenNewCommitsIsOutstanding() {
        // Any review type, then the author pushed → re-review is your move.
        for state in ["COMMENTED", "CHANGES_REQUESTED", "APPROVED"] {
            let s = status(latestReview: state, reviewedHead: "old", head: "new")
            XCTAssertTrue(s.reviewActionOutstanding, "\(state) + new commits → outstanding")
        }
    }

    func testApprovedCurrentHeadButThreadAwaitingIsOutstanding() {
        // Even approved-and-current, an unresolved thread where someone else
        // spoke last is your move (reply/resolve).
        let s = status(latestReview: "APPROVED", reviewedHead: "abc", head: "abc", unresolvedAwaiting: 1)
        XCTAssertTrue(s.reviewActionOutstanding)
    }
}
