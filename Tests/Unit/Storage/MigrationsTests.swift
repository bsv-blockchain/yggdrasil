import GRDB
import XCTest
@testable import Yggdrasil

final class MigrationsTests: XCTestCase {
    func testV1CreatesAllRequiredTables() throws {
        let db = try YggdrasilDatabase.inMemory()
        let tables = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        // Per spec §3.2: setting, repo, task, task_assignee, github_status.
        // sqlite_sequence appears when a table uses AUTOINCREMENT.
        XCTAssertTrue(tables.contains("setting"), "tables=\(tables)")
        XCTAssertTrue(tables.contains("repo"), "tables=\(tables)")
        XCTAssertTrue(tables.contains("task"), "tables=\(tables)")
        XCTAssertTrue(tables.contains("task_assignee"), "tables=\(tables)")
        XCTAssertTrue(tables.contains("github_status"), "tables=\(tables)")
    }

    func testRepoUniqueConstraintOnOwnerName() throws {
        let db = try YggdrasilDatabase.inMemory()
        try db.queue.write { db in
            var first = Repo(
                id: nil,
                owner: "bsv-blockchain",
                name: "teranode",
                defaultBranch: "main",
                localMainPath: nil,
                addedAt: Date(timeIntervalSince1970: 1_700_000_000)
            )
            try first.insert(db)
        }
        XCTAssertThrowsError(try db.queue.write { db in
            var dup = Repo(
                id: nil,
                owner: "bsv-blockchain",
                name: "teranode",
                defaultBranch: "main",
                localMainPath: nil,
                addedAt: Date(timeIntervalSince1970: 1_700_000_001)
            )
            try dup.insert(db)
        })
    }

    func testTaskRoundTripWithAssignees() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "bsv-blockchain", name: "teranode",
                defaultBranch: "main", localMainPath: nil, addedAt: now
            )
            try repo.insert(db)
            let repoID = repo.id!

            var task = YggdrasilTask(
                id: nil, repoID: repoID, type: .pullRequest, number: 655,
                title: "Add diff engine", body: "PR body…",
                state: .open, authorLogin: "sigi",
                githubURL: "https://github.com/bsv-blockchain/teranode/pull/655",
                apiURL: "https://api.github.com/repos/bsv-blockchain/teranode/pulls/655",
                createdAt: now, updatedAt: now, lastSyncedAt: now,
                etag: "W/\"abc\""
            )
            try task.insert(db)
            let taskID = task.id!

            try TaskAssignee(taskID: taskID, login: "sigi").insert(db)
            try TaskAssignee(taskID: taskID, login: "alice").insert(db)
        }

        let logins = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT login FROM task_assignee ORDER BY login"
            )
        }
        XCTAssertEqual(logins, ["alice", "sigi"])
    }

    func testTaskUniqueOnRepoTypeNumber() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "o", name: "r",
                defaultBranch: "main", localMainPath: nil, addedAt: now
            )
            try repo.insert(db)
            let repoID = repo.id!

            var task = YggdrasilTask(
                id: nil, repoID: repoID, type: .issue, number: 1,
                title: "t", body: nil, state: .open, authorLogin: "a",
                githubURL: "u", apiURL: "u",
                createdAt: now, updatedAt: now, lastSyncedAt: now,
                etag: nil
            )
            try task.insert(db)
        }
        XCTAssertThrowsError(try db.queue.write { db in
            var dup = YggdrasilTask(
                id: nil, repoID: 1, type: .issue, number: 1,
                title: "t2", body: nil, state: .open, authorLogin: "a",
                githubURL: "u", apiURL: "u",
                createdAt: now, updatedAt: now, lastSyncedAt: now,
                etag: nil
            )
            try dup.insert(db)
        })
    }

    func testDeletingRepoCascadesToTasksAndAssignees() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "o", name: "r",
                defaultBranch: "main", localMainPath: nil, addedAt: now
            )
            try repo.insert(db)
            let repoID = repo.id!

            var task = YggdrasilTask(
                id: nil, repoID: repoID, type: .issue, number: 1,
                title: "t", body: nil, state: .open, authorLogin: "a",
                githubURL: "u", apiURL: "u",
                createdAt: now, updatedAt: now, lastSyncedAt: now,
                etag: nil
            )
            try task.insert(db)
            try TaskAssignee(taskID: task.id!, login: "x").insert(db)

            try repo.delete(db)
        }
        let taskCount = try db.queue.read { db in try YggdrasilTask.fetchCount(db) }
        let assigneeCount = try db.queue.read { db in try TaskAssignee.fetchCount(db) }
        XCTAssertEqual(taskCount, 0)
        XCTAssertEqual(assigneeCount, 0)
    }

    func testV8AddsUpstreamColumnsAndRoundTrips() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "freemans13", name: "teranode",
                defaultBranch: "main", localMainPath: nil, addedAt: now,
                upstreamOwner: "bsv-blockchain", upstreamName: "teranode",
                upstreamCheckedAt: now
            )
            try repo.insert(db)
        }
        let read = try db.queue.read { db in
            try Repo.fetchOne(db, sql: "SELECT * FROM repo WHERE owner = 'freemans13'")
        }
        XCTAssertEqual(read?.upstreamOwner, "bsv-blockchain")
        XCTAssertEqual(read?.upstreamName, "teranode")
        XCTAssertEqual(read?.upstreamCheckedAt, now)
        XCTAssertEqual(read?.issueSources.count, 2)
    }

    func testGitHubStatusRoundTrip() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let status = try db.queue.write { db -> GitHubStatus in
            var repo = Repo(
                id: nil, owner: "o", name: "r",
                defaultBranch: "main", localMainPath: nil, addedAt: now
            )
            try repo.insert(db)

            var task = YggdrasilTask(
                id: nil, repoID: repo.id!, type: .pullRequest, number: 1,
                title: "t", body: nil, state: .open, authorLogin: "a",
                githubURL: "u", apiURL: "u",
                createdAt: now, updatedAt: now, lastSyncedAt: now,
                etag: nil
            )
            try task.insert(db)

            let status = GitHubStatus(
                taskID: task.id!, ciState: "success", ciURL: "https://ci",
                mergeable: true, mergeableState: "clean",
                reviewState: "APPROVED", unreadCommentsCount: 0,
                lastSeenCommentID: nil, fetchedAt: now,
                commentsReviewsTotal: 0, commitsTotal: 0, headSHA: nil,
                seenCommentsReviewsTotal: nil, seenCommitsTotal: nil, seenHeadSHA: nil
            )
            try status.insert(db)
            return status
        }
        let read = try db.queue.read { db in
            try GitHubStatus.fetchOne(db, key: status.taskID)
        }
        XCTAssertEqual(read?.ciState, "success")
        XCTAssertEqual(read?.mergeable, true)
        XCTAssertEqual(read?.reviewState, "APPROVED")
    }

    func testV9AddsViewerReviewColumnsAndRoundTrips() throws {
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
                viewerLatestReviewState: "APPROVED",
                viewerReviewedHeadSHA: "head",
                unresolvedThreadsAwaitingViewer: 2
            )
            try status.insert(db)
            return task.id!
        }
        let read = try db.queue.read { db in try GitHubStatus.fetchOne(db, key: taskID) }
        XCTAssertEqual(read?.viewerLatestReviewState, "APPROVED")
        XCTAssertEqual(read?.viewerReviewedHeadSHA, "head")
        XCTAssertEqual(read?.unresolvedThreadsAwaitingViewer, 2)
        XCTAssertTrue(read?.reviewCoversCurrentHead ?? false)
        // Reviewed the current head, but 2 threads awaiting → still outstanding.
        XCTAssertTrue(read?.reviewActionOutstanding ?? false)
    }
}
