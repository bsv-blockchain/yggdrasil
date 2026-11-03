import GRDB
import XCTest
@testable import Yggdrasil

/// The two lists behind Assigned Tasks and Review Requests, shared with the
/// sidebar's counts so a picker and its badge can't disagree.
final class TaskQueriesTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var repoID: Int64!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        repoID = try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "acme", name: "widget", defaultBranch: "main", localMainPath: "/w", addedAt: Date()
            )
            try repo.insert(db)
            return repo.id!
        }
    }

    func testToReviewIsRequestedPlusAssignedButNotMine() throws {
        let requested = try addTask(.pullRequest, 1, tables: ["pr_review_request"])
        let assigned = try addTask(.pullRequest, 2, tables: ["pr_assigned"])
        _ = try addTask(.pullRequest, 3, tables: ["pr_assigned", "pr_authored"])
        _ = try addTask(.issue, 4, tables: [])

        let ids = try db.queue.read { db in try TaskQueries.toReview(db).compactMap(\.id) }

        XCTAssertEqual(Set(ids), [requested, assigned])
        XCTAssertEqual(try db.queue.read { db in try TaskQueries.toReviewCount(db) }, 2)
    }

    func testAssignedIsIssuesPlusMyPRs() throws {
        let issue = try addTask(.issue, 1, tables: [])
        let mine = try addTask(.pullRequest, 2, tables: ["pr_authored"])
        _ = try addTask(.pullRequest, 3, tables: ["pr_review_request"])

        let ids = try db.queue.read { db in try TaskQueries.assigned(db).compactMap(\.id) }

        XCTAssertEqual(Set(ids), [issue, mine])
        XCTAssertEqual(try db.queue.read { db in try TaskQueries.assignedCount(db) }, 2)
    }

    func testTasksAlreadyOpenAsATabOrLinkedPRAreLeftOut() throws {
        let issue = try addTask(.issue, 1, tables: [])
        let linkedPR = try addTask(.pullRequest, 2, tables: ["pr_authored"])
        let open = try addTask(.issue, 3, tables: [])
        let store = TabStore(database: db)
        let tab = try store.insert(branchName: "issue-1", worktreePath: "/w/x", agentID: nil, taskID: issue)
        try store.setPRTaskID(id: XCTUnwrap(tab.id), prTaskID: linkedPR)

        let ids = try db.queue.read { db in try TaskQueries.assigned(db).compactMap(\.id) }

        XCTAssertEqual(ids, [open])
        XCTAssertEqual(try db.queue.read { db in try TaskQueries.assignedCount(db) }, 1)
    }

    func testReviewsAlreadyOpenAsATabAreLeftOut() throws {
        let open = try addTask(.pullRequest, 1, tables: ["pr_review_request"])
        let waiting = try addTask(.pullRequest, 2, tables: ["pr_review_request"])
        try TabStore(database: db).insert(branchName: "review-pr-1", worktreePath: "/w/x", agentID: nil, taskID: open)

        let ids = try db.queue.read { db in try TaskQueries.toReview(db).compactMap(\.id) }

        XCTAssertEqual(ids, [waiting])
        XCTAssertEqual(try db.queue.read { db in try TaskQueries.toReviewCount(db) }, 1)
    }

    private func addTask(_ type: YggdrasilTask.Kind, _ number: Int, tables: [String]) throws -> Int64 {
        try db.queue.write { db in
            var task = YggdrasilTask(
                id: nil, repoID: repoID, type: type, number: number,
                title: "T\(number)", body: nil, state: .open, authorLogin: "someone",
                githubURL: "https://github.com/acme/widget/\(number)", apiURL: "",
                createdAt: Date(), updatedAt: Date(), lastSyncedAt: Date(),
                etag: nil, labelsJSON: "[]", milestoneTitle: nil
            )
            try task.insert(db)
            for table in tables {
                let column = table == "pr_review_request" ? "requested_at" : "recorded_at"
                try db.execute(
                    sql: "INSERT INTO \(table) (task_id, \(column)) VALUES (?, ?)", arguments: [task.id, Date()]
                )
            }
            return task.id!
        }
    }
}
