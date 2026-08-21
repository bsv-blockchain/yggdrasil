import XCTest
@testable import Yggdrasil

/// v14 adds `github_status.viewer_review_requested_at` — when the viewer was
/// last asked to review, which decides whether an open request still counts as
/// their move.
final class MigrationV14Tests: XCTestCase {
    func testV14AddsRequestTimestampAndRoundTrips() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let requested = now.addingTimeInterval(-1000)
        let taskID = try db.queue.write { db -> Int64 in
            var repo = Repo(
                id: nil, owner: "o", name: "r",
                defaultBranch: "main", localMainPath: nil, addedAt: now
            )
            try repo.insert(db)
            var task = YggdrasilTask(
                id: nil, repoID: repo.id!, type: .pullRequest, number: 1,
                title: "t", body: nil, state: .open, authorLogin: "a",
                githubURL: "u", apiURL: "u",
                createdAt: now, updatedAt: now, lastSyncedAt: now, etag: nil
            )
            try task.insert(db)
            var status = GitHubStatus(
                taskID: task.id!, ciState: nil, ciURL: nil, mergeable: nil,
                mergeableState: nil, reviewState: nil, unreadCommentsCount: 0,
                lastSeenCommentID: nil, fetchedAt: now,
                commentsReviewsTotal: 0, commitsTotal: 0, headSHA: "head",
                seenCommentsReviewsTotal: nil, seenCommitsTotal: nil, seenHeadSHA: nil,
                viewerLatestReviewState: nil, viewerReviewedHeadSHA: nil,
                unresolvedThreadsAwaitingViewer: 0,
                viewerLastEngagementAt: now, headCommittedAt: nil,
                viewerReviewRequested: true,
                viewerDidAuthorPR: false,
                viewerReviewRequestedAt: requested
            )
            try status.insert(db)
            return task.id!
        }
        let read = try db.queue.read { db in try GitHubStatus.fetchOne(db, key: taskID) }
        XCTAssertEqual(read?.viewerReviewRequestedAt, requested)
        // Asked before I last spoke → answered → not outstanding.
        XCTAssertFalse(read?.reviewRequestOutstanding ?? true)
        XCTAssertFalse(read?.reviewActionOutstanding ?? true)
    }
}
