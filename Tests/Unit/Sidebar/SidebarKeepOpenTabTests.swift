import XCTest
@testable import Yggdrasil

/// The open tab stays in the sidebar when a pill or search stops matching it,
/// so it doesn't vanish (with its context menu) while you're working in it.
final class SidebarKeepOpenTabTests: XCTestCase {
    private func tab(_ id: Int64) -> YggdrasilTab {
        YggdrasilTab(
            id: id, taskID: nil, codingAgentID: nil,
            position: Int(id),
            branchName: "b\(id)", worktreePath: "/tmp/b\(id)",
            lastMainView: .agent,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func ids(_ tabs: [YggdrasilTab]) -> [Int64] {
        tabs.compactMap(\.id)
    }

    func testTheOpenTabStaysInItsPlaceWhenTheFilterDropsIt() {
        let all = [tab(1), tab(2), tab(3)]
        let kept = SidebarView.keepingOpenTab(matching: [tab(1), tab(3)], all: all, selectedID: 2)
        XCTAssertEqual(ids(kept), [1, 2, 3])
    }

    func testTheOpenTabIsKeptEvenWhenNothingElseMatches() {
        let kept = SidebarView.keepingOpenTab(matching: [], all: [tab(1), tab(2)], selectedID: 2)
        XCTAssertEqual(ids(kept), [2])
    }

    func testAMatchingOpenTabIsNotDuplicated() {
        let matching = [tab(1), tab(2)]
        let kept = SidebarView.keepingOpenTab(matching: matching, all: [tab(1), tab(2), tab(3)], selectedID: 2)
        XCTAssertEqual(ids(kept), [1, 2])
    }

    func testNoSelectionOrASelectionOutsideTheTabsChangesNothing() {
        let all = [tab(1), tab(2)]
        XCTAssertEqual(ids(SidebarView.keepingOpenTab(matching: [tab(1)], all: all, selectedID: nil)), [1])
        // The Yggdrasil session row isn't in the tab list.
        XCTAssertEqual(ids(SidebarView.keepingOpenTab(matching: [tab(1)], all: all, selectedID: 99)), [1])
    }
}
