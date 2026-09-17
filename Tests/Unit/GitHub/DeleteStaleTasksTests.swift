import GRDB
import XCTest
@testable import Yggdrasil

/// `TaskSyncWrites.deleteStaleTasks` drops every task that fell out of the
/// synced lists — except the ones a live tab points at. Both pointers count:
/// `task_id` and `pr_task_id`.
final class DeleteStaleTasksTests: XCTestCase {
    private func insertRepo(_ db: YggdrasilDatabase, owner: String, name: String) throws -> Int64 {
        try db.queue.write { dbW in
            var repo = Repo(
                id: nil, owner: owner, name: name,
                defaultBranch: "main", localMainPath: nil,
                addedAt: Date(timeIntervalSince1970: 0)
            )
            try repo.insert(dbW)
            return repo.id!
        }
    }

    func test_deleteStaleTasks_keepsTabLinkedTasks() throws {
        let db = try YggdrasilDatabase.inMemory()
        let repoID = try insertRepo(db, owner: "o", name: "r")
        let epoch = Date(timeIntervalSince1970: 0)

        let survivingNumbers: [Int] = try db.queue.write { dbW -> [Int] in
            func makeTask(_ number: Int) throws -> Int64 {
                var task = YggdrasilTask(
                    id: nil, repoID: repoID, type: .pullRequest, number: number,
                    title: "t\(number)", body: nil, state: .open, authorLogin: "x",
                    githubURL: "", apiURL: "",
                    createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
                    etag: nil, labelsJSON: "[]", milestoneTitle: nil
                )
                try task.insert(dbW)
                return task.id!
            }
            let linkedID = try makeTask(101)
            _ = try makeTask(102) // unlinked → should be pruned

            var tab = YggdrasilTab(
                id: nil, taskID: linkedID, codingAgentID: nil, position: 0,
                branchName: "feat/x", worktreePath: "/tmp/x", lastMainView: .agent,
                createdAt: epoch, lastActiveAt: epoch
            )
            try tab.insert(dbW)

            let repo = try Repo.fetchOne(dbW, key: repoID)!
            // Empty fetched-set: BOTH tasks are stale by the synced-list rule.
            // Only the tab-linked one (101) must survive.
            try TaskSyncWrites.deleteStaleTasks(db: dbW, repos: [repo], fetched: [])

            return try Int.fetchAll(dbW, sql: "SELECT number FROM task ORDER BY number")
        }

        XCTAssertEqual(survivingNumbers, [101],
                       "tab-linked task survives prune; unlinked stale task is deleted")
    }

    /// `pr_task_id` — the PR manually linked to an issue tab — protects its
    /// task just as `task_id` does. It didn't, so the sync could delete that PR
    /// underneath the tab; the FK is ON DELETE SET NULL, so the link the user
    /// made by hand just vanished rather than failing loudly.
    func test_deleteStaleTasks_keepsTasksLinkedOnlyViaPRTaskID() throws {
        let db = try YggdrasilDatabase.inMemory()
        let repoID = try insertRepo(db, owner: "o", name: "r")
        let epoch = Date(timeIntervalSince1970: 0)

        let survivingNumbers: [Int] = try db.queue.write { dbW -> [Int] in
            func makeTask(_ number: Int, type: YggdrasilTask.Kind) throws -> Int64 {
                var task = YggdrasilTask(
                    id: nil, repoID: repoID, type: type, number: number,
                    title: "t\(number)", body: nil, state: .open, authorLogin: "x",
                    githubURL: "", apiURL: "",
                    createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
                    etag: nil, labelsJSON: "[]", milestoneTitle: nil
                )
                try task.insert(dbW)
                return task.id!
            }
            let issueID = try makeTask(201, type: .issue)
            let linkedPRID = try makeTask(202, type: .pullRequest)
            _ = try makeTask(203, type: .pullRequest) // unlinked → pruned

            var tab = YggdrasilTab(
                id: nil, taskID: issueID, prTaskID: linkedPRID, codingAgentID: nil,
                position: 0, branchName: "claude-issue-201", worktreePath: "/tmp/x",
                lastMainView: .agent, createdAt: epoch, lastActiveAt: epoch
            )
            try tab.insert(dbW)

            let repo = try Repo.fetchOne(dbW, key: repoID)!
            try TaskSyncWrites.deleteStaleTasks(db: dbW, repos: [repo], fetched: [])

            return try Int.fetchAll(dbW, sql: "SELECT number FROM task ORDER BY number")
        }

        XCTAssertEqual(survivingNumbers, [201, 202],
                       "both the issue and its linked PR survive; the unlinked PR is pruned")
    }
}
