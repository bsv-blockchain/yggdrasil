import XCTest
@testable import Yggdrasil

final class TabStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var store: TabStore!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        store = TabStore(database: db)
    }

    override func tearDown() {
        db = nil
        store = nil
        super.tearDown()
    }

    func testListIsEmptyOnFreshDatabase() throws {
        XCTAssertTrue(try store.list().isEmpty)
    }

    func testInsertAssignsIncreasingPositions() throws {
        let one = try store.insert(branchName: "feat/foo", worktreePath: "/tmp/foo", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "feat/bar", worktreePath: "/tmp/bar", agentID: nil, taskID: nil)
        let three = try store.insert(branchName: "feat/baz", worktreePath: "/tmp/baz", agentID: nil, taskID: nil)
        XCTAssertEqual(one.position, 0)
        XCTAssertEqual(two.position, 1)
        XCTAssertEqual(three.position, 2)

        let all = try store.list()
        XCTAssertEqual(all.map(\.branchName), ["feat/foo", "feat/bar", "feat/baz"])
    }

    /// Insert a real Repo + YggdrasilTask so the `tab.task_id` foreign-key
    /// constraint is satisfiable. Returns the inserted task id.
    private func insertFixtureTask() throws -> Int64 {
        try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "fix", name: "ture",
                defaultBranch: "main", localMainPath: nil,
                addedAt: Date(timeIntervalSince1970: 0)
            )
            try repo.insert(db)
            var task = YggdrasilTask(
                id: nil, repoID: repo.id!, type: .pullRequest,
                number: 643, title: "fix",
                body: nil, state: .open, authorLogin: "me",
                githubURL: "", apiURL: "",
                createdAt: Date(timeIntervalSince1970: 0),
                updatedAt: Date(timeIntervalSince1970: 0),
                lastSyncedAt: Date(timeIntervalSince1970: 0),
                etag: nil, labelsJSON: "[]", milestoneTitle: nil
            )
            try task.insert(db)
            return task.id!
        }
    }

    func testSetTaskIDLinksTabToTask() throws {
        let taskID = try insertFixtureTask()
        let tab = try store.insert(
            branchName: "claude-pr-643", worktreePath: "/tmp/x",
            agentID: nil, taskID: nil
        )
        XCTAssertNil(tab.taskID, "fresh tab starts with no task linkage")
        try store.setTaskID(id: XCTUnwrap(tab.id), taskID: taskID)
        let reloaded = try store.get(id: XCTUnwrap(tab.id))
        XCTAssertEqual(reloaded?.taskID, taskID)
    }

    func testSetTaskIDCanClearLinkWithNil() throws {
        let taskID = try insertFixtureTask()
        let tab = try store.insert(
            branchName: "x", worktreePath: "/x",
            agentID: nil, taskID: taskID
        )
        try store.setTaskID(id: XCTUnwrap(tab.id), taskID: nil)
        let reloaded = try store.get(id: XCTUnwrap(tab.id))
        XCTAssertNil(reloaded?.taskID)
    }

    func testSetPRTaskIDPersistsAndClears() throws {
        // Also exercises migration v6 (the pr_task_id column) + the model's
        // CodingKey, since the in-memory DB runs the full migrator.
        let prTaskID = try insertFixtureTask()
        let tab = try store.insert(
            branchName: "claude-issue-1001", worktreePath: "/tmp/i",
            agentID: nil, taskID: nil
        )
        XCTAssertNil(tab.prTaskID, "fresh tab has no linked PR")
        try store.setPRTaskID(id: XCTUnwrap(tab.id), prTaskID: prTaskID)
        XCTAssertEqual(try store.get(id: XCTUnwrap(tab.id))?.prTaskID, prTaskID)
        try store.setPRTaskID(id: XCTUnwrap(tab.id), prTaskID: nil)
        XCTAssertNil(try store.get(id: XCTUnwrap(tab.id))?.prTaskID)
    }

    func testDeleteRemovesRow() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        try store.delete(id: XCTUnwrap(one.id))
        XCTAssertEqual(try store.list().map(\.id), try [XCTUnwrap(two.id)])
    }

    func testReorderRewritesPositionsInGivenOrder() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        let three = try store.insert(branchName: "c", worktreePath: "/c", agentID: nil, taskID: nil)

        // Reverse the order.
        try store.reorder(ids: [XCTUnwrap(three.id), XCTUnwrap(two.id), XCTUnwrap(one.id)])
        let listed = try store.list()
        XCTAssertEqual(listed.map(\.branchName), ["c", "b", "a"])
        XCTAssertEqual(listed.map(\.position), [0, 1, 2])
    }

    func testReorderRejectsMissingIDs() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        XCTAssertThrowsError(try store.reorder(ids: [XCTUnwrap(one.id), 999]))
    }

    func testReorderRejectsExtraOrMissingTabIDs() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        // Only one of the two real ids → mismatch.
        XCTAssertThrowsError(try store.reorder(ids: [XCTUnwrap(one.id)]))
        // Both real ids but in the wrong shape is OK.
        XCTAssertNoThrow(try store.reorder(ids: [XCTUnwrap(two.id), XCTUnwrap(one.id)]))
    }

    func testSetLastMainViewPersists() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        XCTAssertEqual(one.lastMainView, .agent)
        try store.setLastMainView(id: XCTUnwrap(one.id), view: .github)
        let refetched = try XCTUnwrap(try store.get(id: XCTUnwrap(one.id)))
        XCTAssertEqual(refetched.lastMainView, .github)
    }

    func testTouchLastActiveAtUpdatesTimestamp() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let before = one.lastActiveAt
        Thread.sleep(forTimeInterval: 0.01)
        try store.touchLastActiveAt(id: XCTUnwrap(one.id))
        let updated = try XCTUnwrap(try store.get(id: XCTUnwrap(one.id)))
        XCTAssertGreaterThan(updated.lastActiveAt, before)
    }
}
