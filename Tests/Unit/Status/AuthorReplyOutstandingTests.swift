import XCTest
@testable import Yggdrasil

/// On a PR the viewer authored, an unresolved review thread whose last comment
/// isn't theirs is their move — whether or not they ever replied in it. Drives
/// the amber REPLY pill, and is deliberately separate from the reviewer-side
/// `reviewActionOutstanding` (which would fire on the author's own pushes).
final class AuthorReplyOutstandingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func status(
        didAuthor: Bool,
        threadsAwaiting: Int,
        engagedAt: Date? = nil,
        headCommittedAt: Date? = nil
    ) -> GitHubStatus {
        GitHubStatus(
            taskID: 1, ciState: nil, ciURL: nil, mergeable: nil, mergeableState: nil,
            reviewState: nil, unreadCommentsCount: 0, lastSeenCommentID: nil,
            fetchedAt: base,
            commentsReviewsTotal: 0, commitsTotal: 0, headSHA: "abc",
            seenCommentsReviewsTotal: nil, seenCommitsTotal: nil, seenHeadSHA: nil,
            viewerLatestReviewState: nil, viewerReviewedHeadSHA: nil,
            unresolvedThreadsAwaitingViewer: threadsAwaiting,
            viewerLastEngagementAt: engagedAt, headCommittedAt: headCommittedAt,
            viewerReviewRequested: false,
            viewerDidAuthorPR: didAuthor
        )
    }

    func testAuthoredWithThreadsAwaitingIsOutstanding() {
        // The 1385 case: 4 threads from a reviewer, none replied to.
        XCTAssertTrue(status(didAuthor: true, threadsAwaiting: 4).authorReplyOutstanding)
    }

    func testAuthoredWithNoThreadsIsNotOutstanding() {
        XCTAssertFalse(status(didAuthor: true, threadsAwaiting: 0).authorReplyOutstanding)
    }

    func testNotAuthoredIsNeverAuthorReply() {
        // Someone else's PR: the reviewer-side signals own that case.
        XCTAssertFalse(status(didAuthor: false, threadsAwaiting: 4).authorReplyOutstanding)
    }

    func testMyOwnPushDoesNotMakeItOutstanding() {
        // Pushing to my own PR moves the head past my last comment. That must
        // not read as "someone is waiting for me" — only threads do.
        let pushed = status(
            didAuthor: true, threadsAwaiting: 0,
            engagedAt: base, headCommittedAt: base.addingTimeInterval(100)
        )
        XCTAssertTrue(pushed.commitsAfterEngagement)
        XCTAssertFalse(pushed.authorReplyOutstanding)
    }
}
