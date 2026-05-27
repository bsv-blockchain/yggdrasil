@testable import Loom
import XCTest

final class TabsModelTests: XCTestCase {
    private var db: LoomDatabase!
    private var store: TabStore!
    private var model: TabsModel!

    override func setUpWithError() throws {
        db = try LoomDatabase.inMemory()
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
        model.select(second.id!)
        model.reload()
        XCTAssertEqual(model.selectedID, second.id)
    }

    func testReloadDropsSelectionIfRowDeleted() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        model.select(first.id!)
        try store.delete(id: first.id!)
        model.reload()
        XCTAssertEqual(model.selectedID, second.id, "selection falls back to the first remaining tab")
    }

    func testMoveSelectionDown() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let second = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        model.select(first.id!)
        model.moveSelection(by: 1)
        XCTAssertEqual(model.selectedID, second.id)
    }

    func testMoveSelectionUpClampsAtTop() throws {
        let first = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        _ = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        model.reload()
        model.select(first.id!)
        model.moveSelection(by: -1)
        XCTAssertEqual(model.selectedID, first.id, "moveSelection clamps; can't go above the top")
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
}
