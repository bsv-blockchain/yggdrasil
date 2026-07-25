import XCTest
@testable import Yggdrasil

final class TabsModelTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var store: TabStore!
    private var model: TabsModel!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        store = TabStore(database: db)
        model = TabsModel(store: store, database: db)
    }

    override func tearDown() {
        db = nil
        store = nil
        model = nil
        super.tearDown()
    }

    func testReloadStartsEmpty() {
        model.reload()
        XCTAssertTrue(model.tabs.isEmpty)
        XCTAssertNil(model.selectedID)
    }

    func testReloadPicksFirstTabAsSelectionWhenNothingSelected() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        _ = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        XCTAssertEqual(model.selectedID, first.id)
    }

    func testReloadPreservesSelectionIfStillPresent() throws {
        _ = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        try model.select(XCTUnwrap(second.id))
        model.reload()
        XCTAssertEqual(model.selectedID, second.id)
    }

    func testReloadDropsSelectionIfRowDeleted() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        try model.select(XCTUnwrap(first.id))
        try store.delete(id: XCTUnwrap(first.id))
        model.reload()
        XCTAssertEqual(model.selectedID, second.id, "selection falls back to the first remaining tab")
    }

    func testMoveSelectionDown() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        try model.select(XCTUnwrap(first.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, second.id)
    }

    func testMoveSelectionUpWrapsToBottom() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        try model.select(XCTUnwrap(first.id))
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, second.id, "moving up from the first tab wraps to the last")
    }

    func testMoveSelectionDownWrapsToTop() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        try model.select(XCTUnwrap(second.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, first.id, "moving down from the last tab wraps to the first")
    }

    func testMoveSelectionSingleTabIsNoOp() throws {
        let only = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        model.reload()
        try model.select(XCTUnwrap(only.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, only.id)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, only.id)
    }

    func testMoveSelectionWalksVisibleOrderSkippingFilteredRows() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        _ = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        let third = try store.insert(branchName: "c", worktreePath: "/c", agentID: nil, taskID: nil)
        model.reload()
        // Sidebar is showing only a and c (b filtered out).
        model.visibleTabIDs = try [XCTUnwrap(first.id), XCTUnwrap(third.id)]
        try model.select(XCTUnwrap(first.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, third.id, "steps to the next visible row, skipping the hidden one")
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, first.id, "wraps within the visible set")
    }

    func testMoveSelectionUsesDisplayOrderNotPersistedOrder() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        // Grouping renders b above a.
        model.visibleTabIDs = try [XCTUnwrap(second.id), XCTUnwrap(first.id)]
        try model.select(XCTUnwrap(second.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, first.id, "follows rendered order, not the persisted list")
    }

    func testMoveSelectionFromHiddenSelectionEntersVisibleListFromNearEnd() throws {
        let hidden = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        let third = try store.insert(branchName: "c", worktreePath: "/c", agentID: nil, taskID: nil)
        model.reload()
        model.visibleTabIDs = try [XCTUnwrap(second.id), XCTUnwrap(third.id)]

        try model.select(XCTUnwrap(hidden.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, second.id, "moving down enters at the first visible row")

        try model.select(XCTUnwrap(hidden.id))
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, third.id, "moving up enters at the last visible row")
    }

    func testMoveSelectionFallsBackToAllTabsWhenNothingRendered() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        XCTAssertTrue(model.visibleTabIDs.isEmpty)
        try model.select(XCTUnwrap(first.id))
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, second.id)
    }

    func testFilteredByQueryMatchesBranchSubstring() throws {
        _ = try store.insert(branchName: "feat/foo", worktreePath: "/a", agentID: nil, taskID: nil)
        _ = try store.insert(branchName: "feat/bar", worktreePath: "/b", agentID: nil, taskID: nil)
        _ = try store.insert(branchName: "fix/baz", worktreePath: "/c", agentID: nil, taskID: nil)
        model.reload()

        XCTAssertEqual(model.filtered(by: "feat").map(\.branchName), ["feat/foo", "feat/bar"])
        XCTAssertEqual(model.filtered(by: "bar").map(\.branchName), ["feat/bar"])
        XCTAssertEqual(model.filtered(by: "FIX").map(\.branchName), ["fix/baz"],
                       "matching is case-insensitive")
    }

    func testFilteredEmptyQueryReturnsAllTabs() throws {
        _ = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        _ = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        XCTAssertEqual(model.filtered(by: "").count, 2)
        XCTAssertEqual(model.filtered(by: "   ").count, 2, "whitespace-only counts as empty")
    }

    func testReorderPersistsViaStore() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        let third = try store.insert(branchName: "c", worktreePath: "/c", agentID: nil, taskID: nil)
        model.reload()
        // Move the third tab to the top.
        model.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        XCTAssertEqual(model.tabs.map(\.branchName), ["c", "a", "b"])
        // And it persisted.
        XCTAssertEqual(try store.list().map(\.branchName), ["c", "a", "b"])
        _ = first
        _ = second
        _ = third
    }

    func testPendingAssignedCountExcludesTabPrimaryAndLinkedPR() throws {
        let epoch = Date(timeIntervalSince1970: 0)
        let (issueID, prID) = try db.queue.write { db -> (Int64, Int64) in
            var repo = Repo(
                id: nil, owner: "o", name: "r", defaultBranch: "main",
                localMainPath: nil, addedAt: epoch
            )
            try repo.insert(db)
            let repoID = try XCTUnwrap(repo.id)
            func makeTask(_ type: YggdrasilTask.Kind, _ number: Int) throws -> Int64 {
                var task = YggdrasilTask(
                    id: nil, repoID: repoID, type: type, number: number, title: "t",
                    body: nil, state: .open, authorLogin: "me", githubURL: "", apiURL: "",
                    createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
                    etag: nil, labelsJSON: "[]", milestoneTitle: nil
                )
                try task.insert(db)
                return try XCTUnwrap(task.id)
            }
            let issue = try makeTask(.issue, 1001)
            let pull = try makeTask(.pullRequest, 1042)
            // Authored PR → part of the .assigned candidate set.
            try db.execute(
                sql: "INSERT INTO pr_authored (task_id, recorded_at) VALUES (?, ?)",
                arguments: [pull, epoch]
            )
            return (issue, pull)
        }

        // Nothing open yet: the assigned issue + the authored PR are both pending.
        model.reload()
        XCTAssertEqual(model.pendingAssignedCount, 2)

        // Open the issue as a tab and link the PR to it (pr_task_id) — the
        // regression: the linked PR must drop out of the pending count too.
        let tab = try store.insert(
            branchName: "claude-issue-1001", worktreePath: "/tmp/x",
            agentID: nil, taskID: issueID
        )
        try store.setPRTaskID(id: XCTUnwrap(tab.id), prTaskID: prID)

        model.reload()
        XCTAssertEqual(model.pendingAssignedCount, 0, "issue (task_id) and linked PR (pr_task_id) both excluded")
    }
}
