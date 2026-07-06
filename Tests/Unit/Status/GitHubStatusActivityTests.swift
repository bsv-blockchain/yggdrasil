import XCTest
@testable import Yggdrasil

/// The "activity since last opened" deltas that drive the amber REVIEW pill.
final class GitHubStatusActivityTests: XCTestCase {
    private struct Snap {
        let comments: Int
        let commits: Int
        let head: String?
    }

    private func status(current: Snap, seen: Snap?) -> GitHubStatus {
        GitHubStatus(
            taskID: 1, ciState: nil, ciURL: nil, mergeable: nil, mergeableState: nil,
            reviewState: nil, unreadCommentsCount: 0, lastSeenCommentID: nil,
            fetchedAt: Date(timeIntervalSince1970: 0),
            commentsReviewsTotal: current.comments, commitsTotal: current.commits, headSHA: current.head,
            seenCommentsReviewsTotal: seen?.comments,
            seenCommitsTotal: seen?.commits, seenHeadSHA: seen?.head,
            viewerLatestReviewState: nil, viewerReviewedHeadSHA: nil
        )
    }

    func testNoBaselineMeansNoActivity() {
        // Freshly seen (nil baseline) → nothing is "new" yet.
        let s = status(current: Snap(comments: 5, commits: 3, head: "abc"), seen: nil)
        XCTAssertEqual(s.newCommentsSinceSeen, 0)
        XCTAssertEqual(s.newCommitsSinceSeen, 0)
        XCTAssertFalse(s.headChangedSinceSeen)
        XCTAssertFalse(s.hasActivitySinceSeen)
    }

    func testCaughtUpMeansNoActivity() {
        let s = status(
            current: Snap(comments: 5, commits: 3, head: "abc"),
            seen: Snap(comments: 5, commits: 3, head: "abc")
        )
        XCTAssertFalse(s.hasActivitySinceSeen)
    }

    func testNewCommentsFlagActivity() {
        let s = status(
            current: Snap(comments: 8, commits: 3, head: "abc"),
            seen: Snap(comments: 5, commits: 3, head: "abc")
        )
        XCTAssertEqual(s.newCommentsSinceSeen, 3)
        XCTAssertTrue(s.hasActivitySinceSeen)
    }

    func testNewCommitsFlagActivity() {
        let s = status(
            current: Snap(comments: 5, commits: 5, head: "def"),
            seen: Snap(comments: 5, commits: 3, head: "abc")
        )
        XCTAssertEqual(s.newCommitsSinceSeen, 2)
        XCTAssertTrue(s.hasActivitySinceSeen)
    }

    func testForcePushSameCountDifferentHeadFlagsActivity() {
        // Rebase/amend keeps the commit count but moves the head.
        let s = status(
            current: Snap(comments: 5, commits: 3, head: "rebased"),
            seen: Snap(comments: 5, commits: 3, head: "abc")
        )
        XCTAssertEqual(s.newCommitsSinceSeen, 0)
        XCTAssertTrue(s.headChangedSinceSeen)
        XCTAssertTrue(s.hasActivitySinceSeen)
    }
}
