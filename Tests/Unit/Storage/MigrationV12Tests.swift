import XCTest
@testable import Yggdrasil

/// v12 adds `github_status.viewer_review_requested` — GitHub's own "awaiting
/// requested review from you" bit, which drives the amber REVIEW pill.
final class MigrationV12Tests: XCTestCase {
    func testV12AddsViewerReviewRequestedAndRoundTrips() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
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
                viewerLastEngagementAt: nil, headCommittedAt: nil,
                viewerReviewRequested: true
            )
            try status.insert(db)
            return task.id!
        }
        let read = try db.queue.read { db in try GitHubStatus.fetchOne(db, key: taskID) }
        XCTAssertTrue(read?.viewerReviewRequested ?? false)
        // An open review request alone makes it my move.
        XCTAssertTrue(read?.reviewActionOutstanding ?? false)
    }
}
