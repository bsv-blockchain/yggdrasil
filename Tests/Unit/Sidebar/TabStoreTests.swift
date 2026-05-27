@testable import Yggdrasil
import XCTest

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

    func testDeleteRemovesRow() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        try store.delete(id: one.id!)
        XCTAssertEqual(try store.list().map(\.id), [two.id!])
    }

    func testReorderRewritesPositionsInGivenOrder() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        let three = try store.insert(branchName: "c", worktreePath: "/c", agentID: nil, taskID: nil)

        // Reverse the order.
        try store.reorder(ids: [three.id!, two.id!, one.id!])
        let listed = try store.list()
        XCTAssertEqual(listed.map(\.branchName), ["c", "b", "a"])
        XCTAssertEqual(listed.map(\.position), [0, 1, 2])
    }

    func testReorderRejectsMissingIDs() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        XCTAssertThrowsError(try store.reorder(ids: [one.id!, 999]))
    }

    func testReorderRejectsExtraOrMissingTabIDs() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let two = try store.insert(branchName: "b", worktreePath: "/b", agentID: nil, taskID: nil)
        // Only one of the two real ids → mismatch.
        XCTAssertThrowsError(try store.reorder(ids: [one.id!]))
        // Both real ids but in the wrong shape is OK.
        XCTAssertNoThrow(try store.reorder(ids: [two.id!, one.id!]))
    }

    func testSetLastMainViewPersists() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        XCTAssertEqual(one.lastMainView, .agent)
        try store.setLastMainView(id: one.id!, view: .github)
        let refetched = try XCTUnwrap(try store.get(id: one.id!))
        XCTAssertEqual(refetched.lastMainView, .github)
    }

    func testTouchLastActiveAtUpdatesTimestamp() throws {
        let one = try store.insert(branchName: "a", worktreePath: "/a", agentID: nil, taskID: nil)
        let before = one.lastActiveAt
        Thread.sleep(forTimeInterval: 0.01)
        try store.touchLastActiveAt(id: one.id!)
        let updated = try XCTUnwrap(try store.get(id: one.id!))
        XCTAssertGreaterThan(updated.lastActiveAt, before)
    }
}
