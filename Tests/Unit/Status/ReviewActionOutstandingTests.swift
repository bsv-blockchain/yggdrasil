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
        XCTAssertTrue(s.reviewApprovedCurrentHead)
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testApprovedButNewCommitsIsOutstanding() {
        // Approval covered an older head; author pushed since → re-review.
        let s = status(latestReview: "APPROVED", reviewedHead: "old", head: "new")
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testChangesRequestedIsOutstanding() {
        let s = status(latestReview: "CHANGES_REQUESTED", reviewedHead: "abc", head: "abc")
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testCommentedOnlyIsOutstanding() {
        let s = status(latestReview: "COMMENTED", reviewedHead: "abc", head: "abc")
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testApprovedCurrentHeadButThreadAwaitingIsOutstanding() {
        // Even approved-and-current, an unresolved thread where someone else
        // spoke last is your move (reply/resolve).
        let s = status(latestReview: "APPROVED", reviewedHead: "abc", head: "abc", unresolvedAwaiting: 1)
        XCTAssertTrue(s.reviewActionOutstanding)
    }
}
