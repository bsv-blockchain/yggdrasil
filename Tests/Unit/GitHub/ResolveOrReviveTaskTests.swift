import XCTest
@testable import Yggdrasil

/// The pickers hold a snapshot of the task list from the moment they loaded.
/// Between that load and the user clicking a row, `fullSync`'s prune can delete
/// the task: closing a tab removes the only thing protecting it (the prune
/// keeps tasks referenced by an open tab), and a review you just finished has
/// already dropped out of GitHub's review-requested search. Inserting a tab
/// against that dead id fails the `tab.task_id` foreign key — SQLite error 19.
final class ResolveOrReviveTaskTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var repoID: Int64!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        repoID = try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "bsv-blockchain", name: "teranode",
                defaultBranch: "main", localMainPath: nil,
                addedAt: Date(timeIntervalSince1970: 0)
            )
            try repo.insert(db)
            return repo.id!
        }
    }

    override func tearDown() {
        db = nil
        repoID = nil
        super.tearDown()
    }

    private func makeTask(id: Int64?, number: Int, title: String = "Fix the thing") -> YggdrasilTask {
        YggdrasilTask(
            id: id, repoID: repoID, type: .pullRequest, number: number,
            title: title, body: nil, state: .open, authorLogin: "someone",
            githubURL: "https://github.com/bsv-blockchain/teranode/pull/\(number)",
            apiURL: "https://api.github.com/repos/bsv-blockchain/teranode/pulls/\(number)",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0),
            lastSyncedAt: Date(timeIntervalSince1970: 0),
            etag: nil, labelsJSON: "[]", milestoneTitle: nil
        )
    }

    @discardableResult
    private func insert(_ task: YggdrasilTask) throws -> Int64 {
        try db.queue.write { db in
            var copy = task
            try copy.insert(db)
            return copy.id!
        }
    }

    func testReturnsTheExistingIDWhenTheTaskIsStillThere() throws {
        let id = try insert(makeTask(id: nil, number: 1565))
        let resolved = try db.queue.write { db in
            try TaskSyncWrites.resolveOrReviveTask(db: db, snapshot: makeTask(id: id, number: 1565))
        }
        XCTAssertEqual(resolved, id)
    }

    /// The reported crash: the row is gone, and the snapshot's id is dead.
    func testRevivesTheTaskWhenThePruneDeletedIt() throws {
        let deadID = try insert(makeTask(id: nil, number: 1565))
        try db.queue.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [deadID])
        }

        let resolved = try db.queue.write { db in
            try TaskSyncWrites.resolveOrReviveTask(db: db, snapshot: makeTask(id: deadID, number: 1565))
        }

        let row = try db.queue.read { db in try YggdrasilTask.fetchOne(db, key: resolved) }
        XCTAssertNotNil(row, "revived row must exist")
        XCTAssertEqual(row?.number, 1565)
        XCTAssertEqual(row?.repoID, repoID)
    }

    /// A revived task must be usable as a tab's `task_id` — that insert failing
    /// is the whole bug.
    func testTabInsertAgainstARevivedTaskSucceeds() throws {
        let deadID = try insert(makeTask(id: nil, number: 1565))
        try db.queue.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [deadID])
        }
        let resolved = try db.queue.write { db in
            try TaskSyncWrites.resolveOrReviveTask(db: db, snapshot: makeTask(id: deadID, number: 1565))
        }

        let store = TabStore(database: db)
        let tab = try store.insert(
            branchName: "claude-review-pr-1565", worktreePath: "/tmp/wt",
            agentID: nil, taskID: resolved
        )
        XCTAssertEqual(tab.taskID, resolved)
    }

    /// If the sync re-imported the task under a fresh id while the picker held
    /// the old one, match on the natural key rather than inserting a duplicate
    /// that would violate UNIQUE(repo_id, type, number).
    func testMatchesOnNaturalKeyWhenTheRowWasReimportedWithANewID() throws {
        let staleID = try insert(makeTask(id: nil, number: 1565))
        try db.queue.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [staleID])
        }
        let freshID = try insert(makeTask(id: nil, number: 1565, title: "Re-imported"))
        XCTAssertNotEqual(staleID, freshID)

        let resolved = try db.queue.write { db in
            try TaskSyncWrites.resolveOrReviveTask(db: db, snapshot: makeTask(id: staleID, number: 1565))
        }
        XCTAssertEqual(resolved, freshID, "must reuse the re-imported row, not duplicate it")
        let count = try db.queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE number = 1565") ?? 0
        }
        XCTAssertEqual(count, 1)
    }

    func testRevivedTaskKeepsItsTitleAndURLs() throws {
        let deadID = try insert(makeTask(id: nil, number: 42, title: "Keep me"))
        try db.queue.write { db in
            try db.execute(sql: "DELETE FROM task WHERE id = ?", arguments: [deadID])
        }
        let resolved = try db.queue.write { db in
            try TaskSyncWrites.resolveOrReviveTask(
                db: db, snapshot: makeTask(id: deadID, number: 42, title: "Keep me")
            )
        }
        let row = try db.queue.read { db in try YggdrasilTask.fetchOne(db, key: resolved) }
        XCTAssertEqual(row?.title, "Keep me")
        XCTAssertEqual(row?.githubURL, "https://github.com/bsv-blockchain/teranode/pull/42")
    }
}
