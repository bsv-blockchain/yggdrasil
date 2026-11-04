import XCTest
@testable import Yggdrasil

/// Which tabs the sidebar's PRs / Issues pills keep.
final class SidebarFilterTests: XCTestCase {
    private func task(_ type: YggdrasilTask.Kind, _ number: Int) -> YggdrasilTask {
        let epoch = Date(timeIntervalSince1970: 0)
        return YggdrasilTask(
            id: Int64(number), repoID: 1, type: type, number: number, title: "t",
            body: nil, state: .open, authorLogin: "me", githubURL: "", apiURL: "",
            createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
            etag: nil, labelsJSON: "[]", milestoneTitle: nil
        )
    }

    func testPRsKeepsPRTabs() {
        XCTAssertTrue(SidebarView.Filter.prs.keeps(task: task(.pullRequest, 1938), prTask: nil))
    }

    func testPRsKeepsIssueTabsWithALinkedPR() {
        // The row shows the linked PR's number; searching for it under PRs
        // must find the tab.
        XCTAssertTrue(SidebarView.Filter.prs.keeps(task: task(.issue, 1835), prTask: task(.pullRequest, 1889)))
    }

    func testPRsDropsPlainIssueAndUntaskedTabs() {
        XCTAssertFalse(SidebarView.Filter.prs.keeps(task: task(.issue, 1835), prTask: nil))
        XCTAssertFalse(SidebarView.Filter.prs.keeps(task: nil, prTask: nil))
    }

    func testIssuesKeepsIssueTabsWithOrWithoutALinkedPR() {
        XCTAssertTrue(SidebarView.Filter.issues.keeps(task: task(.issue, 1835), prTask: nil))
        XCTAssertTrue(SidebarView.Filter.issues.keeps(task: task(.issue, 1835), prTask: task(.pullRequest, 1889)))
        XCTAssertFalse(SidebarView.Filter.issues.keeps(task: task(.pullRequest, 1938), prTask: nil))
    }

    func testWorkingKeepsTabsWhoseClaudeIsMidTurn() {
        let busy = TabStatus(icon: .dirty, showsUnreadBadgeDot: false, tooltipLines: [], claudeBusy: true)
        let idle = TabStatus(icon: .idle, showsUnreadBadgeDot: false, tooltipLines: [])
        XCTAssertTrue(SidebarView.Filter.working.keeps(status: busy))
        XCTAssertFalse(SidebarView.Filter.working.keeps(status: idle))
        XCTAssertFalse(SidebarView.Filter.working.keeps(status: nil), "no status yet")
        XCTAssertTrue(SidebarView.Filter.all.keeps(status: nil))
    }
}
