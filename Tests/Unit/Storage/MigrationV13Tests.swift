import XCTest
@testable import Yggdrasil

/// v13 adds `github_status.viewer_did_author_pr`, which gates the amber REPLY
/// pill on PRs the viewer wrote.
final class MigrationV13Tests: XCTestCase {
    func testV13AddsViewerDidAuthorAndRoundTrips() throws {
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
                unresolvedThreadsAwaitingViewer: 2,
                viewerLastEngagementAt: nil, headCommittedAt: nil,
                viewerReviewRequested: false,
                viewerDidAuthorPR: true
            )
            try status.insert(db)
            return task.id!
        }
        let read = try db.queue.read { db in try GitHubStatus.fetchOne(db, key: taskID) }
        XCTAssertTrue(read?.viewerDidAuthorPR ?? false)
        XCTAssertTrue(read?.authorReplyOutstanding ?? false)
    }
}
