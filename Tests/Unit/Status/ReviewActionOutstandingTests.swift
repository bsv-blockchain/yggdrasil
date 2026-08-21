import XCTest
@testable import Yggdrasil

/// The GitHub-derived signals that drive the REVIEW pill: amber when something
/// is directed at the viewer (a push or a reply after their last engagement),
/// green when they've approved the current head. Independent of tab-open state.
final class ReviewActionOutstandingTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private func at(_ offset: TimeInterval) -> Date {
        base.addingTimeInterval(offset)
    }

    private func status(
        latestReview: String? = nil,
        reviewedHead: String? = nil,
        head: String? = "abc",
        engagedAt: Date? = nil,
        headCommittedAt: Date? = nil,
        unresolvedAwaiting: Int = 0,
        reviewRequested: Bool = false,
        requestedAt: Date? = nil
    ) -> GitHubStatus {
        GitHubStatus(
            taskID: 1, ciState: nil, ciURL: nil, mergeable: nil, mergeableState: nil,
            reviewState: nil, unreadCommentsCount: 0, lastSeenCommentID: nil,
            fetchedAt: base,
            commentsReviewsTotal: 0, commitsTotal: 0, headSHA: head,
            seenCommentsReviewsTotal: nil, seenCommitsTotal: nil, seenHeadSHA: nil,
            viewerLatestReviewState: latestReview,
            viewerReviewedHeadSHA: reviewedHead,
            unresolvedThreadsAwaitingViewer: unresolvedAwaiting,
            viewerLastEngagementAt: engagedAt,
            headCommittedAt: headCommittedAt,
            viewerReviewRequested: reviewRequested,
            viewerReviewRequestedAt: requestedAt
        )
    }

    // MARK: - amber (outstanding)

    func testNeverEngagedIsNotOutstanding() {
        XCTAssertFalse(status(engagedAt: nil, headCommittedAt: at(0)).reviewActionOutstanding)
    }

    func testCommitAfterEngagementIsOutstanding() {
        // Author pushed after I last engaged → re-review is my move.
        let s = status(engagedAt: at(0), headCommittedAt: at(100))
        XCTAssertTrue(s.commitsAfterEngagement)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testEngagedAfterCommitIsNotOutstanding() {
        // The 1176 case: author pushed, then I commented — I've looked → blue.
        let s = status(engagedAt: at(100), headCommittedAt: at(0))
        XCTAssertFalse(s.commitsAfterEngagement)
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testOpenReviewRequestIsOutstanding() {
        // GitHub says "awaiting requested review from you" and I've never
        // reviewed → my move, regardless of any timestamp heuristic.
        let s = status(reviewRequested: true, requestedAt: at(0))
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testRequestIsNotOutstandingOnceIActedOnIt() {
        // The 1486 case: I was asked on the 11th and commented on the 21st.
        // The request is still open on GitHub (I never submitted a formal
        // review), but the last move was mine → nothing needs me.
        let s = status(engagedAt: at(1000), reviewRequested: true, requestedAt: at(0))
        XCTAssertFalse(s.reviewRequestOutstanding)
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testRequestNewerThanMyEngagementIsOutstanding() {
        // Re-requested after I last spoke → back to me.
        let s = status(engagedAt: at(0), reviewRequested: true, requestedAt: at(1000))
        XCTAssertTrue(s.reviewRequestOutstanding)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testRequestWithNoEngagementIsOutstanding() {
        // The 1390 case: asked, never engaged.
        let s = status(engagedAt: nil, reviewRequested: true, requestedAt: at(0))
        XCTAssertTrue(s.reviewRequestOutstanding)
    }

    func testRequestWithUnknownRequestTimeIsOutstanding() {
        // Rows written before the request timestamp existed, and PRs whose
        // request predates the fetched timeline: fail toward "your move".
        let s = status(engagedAt: at(1000), reviewRequested: true, requestedAt: nil)
        XCTAssertTrue(s.reviewRequestOutstanding)
    }

    func testStaleRequestTimeWithoutOpenRequestIsNotOutstanding() {
        // Request was withdrawn: the timestamp may linger, the bool is what
        // says whether anything is open.
        let s = status(engagedAt: at(0), reviewRequested: false, requestedAt: at(1000))
        XCTAssertFalse(s.reviewRequestOutstanding)
        XCTAssertFalse(s.reviewActionOutstanding)
    }

    func testPushAfterMyEngagementStillOutstandingDespiteOldRequest() {
        // I answered the request, then the author pushed → my move again, via
        // the commit rule rather than the request rule.
        let s = status(
            engagedAt: at(1000), headCommittedAt: at(2000),
            reviewRequested: true, requestedAt: at(0)
        )
        XCTAssertFalse(s.reviewRequestOutstanding)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testReRequestAfterMyEngagementIsOutstanding() {
        // The reported case: I reviewed/commented, the author pushed fixes and
        // re-requested review. My comment postdates the head commit, so the
        // timestamp rule says nothing — the open request is what makes it mine.
        let s = status(latestReview: "CHANGES_REQUESTED", reviewedHead: "old", head: "new",
                       engagedAt: at(100), headCommittedAt: at(0), reviewRequested: true,
                       requestedAt: at(200))
        XCTAssertFalse(s.commitsAfterEngagement)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testApprovedButReRequestedIsOutstanding() {
        // Stale-but-current approval plus a fresh request → amber wins over green.
        let s = status(latestReview: "APPROVED", reviewedHead: "abc", head: "abc",
                       reviewRequested: true, requestedAt: at(0))
        XCTAssertTrue(s.reviewApprovedByViewer)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    func testNoOpenRequestAndNothingElseIsNotOutstanding() {
        XCTAssertFalse(status(reviewRequested: false).reviewActionOutstanding)
    }

    func testThreadAwaitingIsOutstanding() {
        // A reply after mine in a thread I'm in — even having engaged since a push.
        let s = status(engagedAt: at(100), headCommittedAt: at(0), unresolvedAwaiting: 1)
        XCTAssertTrue(s.reviewActionOutstanding)
    }

    // MARK: - green (approved current head)

    func testApprovedCurrentHeadIsApproved() {
        let s = status(latestReview: "APPROVED", reviewedHead: "abc", head: "abc",
                       engagedAt: at(100), headCommittedAt: at(0))
        XCTAssertTrue(s.reviewApprovedByViewer)
        XCTAssertFalse(s.reviewActionOutstanding, "approved & nothing directed at me → not amber")
    }

    func testApprovedButStaleIsNotApproved() {
        // Approval covered an older head → not "approved current".
        let s = status(latestReview: "APPROVED", reviewedHead: "old", head: "new")
        XCTAssertFalse(s.reviewApprovedByViewer)
    }

    func testCommentedIsNotApproved() {
        let s = status(latestReview: "COMMENTED", reviewedHead: "abc", head: "abc")
        XCTAssertFalse(s.reviewApprovedByViewer)
    }
}
