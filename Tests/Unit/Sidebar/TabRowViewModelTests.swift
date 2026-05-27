import Foundation
@testable import Loom
import XCTest

final class TabRowViewModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTab(
        id: Int64 = 1,
        taskID: Int64? = nil,
        branch: String = "feat/foo",
        worktree: String = "/Users/sigi/code/.worktrees/feat-foo"
    ) -> Tab {
        Tab(
            id: id, taskID: taskID, codingAgentID: nil, position: 0,
            branchName: branch, worktreePath: worktree,
            lastMainView: .agent, createdAt: now, lastActiveAt: now
        )
    }

    private func makeTask(
        type: LoomTask.Kind = .pullRequest,
        number: Int = 655,
        title: String = "Add diff engine"
    ) -> LoomTask {
        LoomTask(
            id: 1, repoID: 1, type: type, number: number, title: title,
            body: nil, state: .open, authorLogin: "sigi",
            githubURL: "https://github.com/o/r/pull/\(number)",
            apiURL: "https://api.github.com/repos/o/r/pulls/\(number)",
            createdAt: now, updatedAt: now, lastSyncedAt: now, etag: nil
        )
    }

    func testRowWithTaskUsesTaskTitle() {
        let vm = TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(title: "Hello"))
        XCTAssertEqual(vm.titleLine, "Hello")
    }

    func testRowWithoutTaskFallsBackToBranchName() {
        let vm = TabRowViewModel(tab: makeTab(taskID: nil, branch: "scratch"), task: nil)
        XCTAssertEqual(vm.titleLine, "scratch")
    }

    func testBranchLineAlwaysShowsTabBranch() {
        let vm = TabRowViewModel(tab: makeTab(branch: "feat/foo"), task: makeTask())
        XCTAssertEqual(vm.branchLine, "feat/foo")
    }

    func testShortWorktreePathIsNotTruncated() {
        let vm = TabRowViewModel(tab: makeTab(worktree: "/short/path"), task: nil)
        XCTAssertEqual(vm.worktreeLine, "/short/path")
    }

    func testLongWorktreePathIsMidEllipsisTruncated() {
        let long = "/Users/sigi/code/work/projects/bsv-blockchain/teranode/.worktrees/feat-some-long-branch-name"
        let vm = TabRowViewModel(tab: makeTab(worktree: long), task: nil, maxWorktreeChars: 40)
        XCTAssertLessThanOrEqual(vm.worktreeLine.count, 40)
        XCTAssertTrue(vm.worktreeLine.contains("…"))
        // Start and end of the original path survive truncation.
        XCTAssertTrue(vm.worktreeLine.hasPrefix("/Users"))
        XCTAssertTrue(vm.worktreeLine.hasSuffix("branch-name") || vm.worktreeLine.hasSuffix("h-name"))
    }

    func testTrailingBadgeForPRIsPRNumber() {
        let vm = TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(type: .pullRequest, number: 655))
        guard case let .prNumber(num) = vm.trailingBadge else {
            return XCTFail("expected .prNumber, got \(vm.trailingBadge)")
        }
        XCTAssertEqual(num, 655)
    }

    func testTrailingBadgeForIssueIsIssueIcon() {
        let vm = TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(type: .issue, number: 42))
        guard case let .issueNumber(num) = vm.trailingBadge else {
            return XCTFail("expected .issueNumber, got \(vm.trailingBadge)")
        }
        XCTAssertEqual(num, 42)
    }

    func testTrailingBadgeForAdHocTabIsNone() {
        let vm = TabRowViewModel(tab: makeTab(taskID: nil), task: nil)
        if case .none = vm.trailingBadge { /* expected */ } else {
            XCTFail("expected .none, got \(vm.trailingBadge)")
        }
    }

    func testStatusIconDefaultsToIdlePlaceholder() {
        // Phase 6 will populate real states. For now the row shows the placeholder.
        let vm = TabRowViewModel(tab: makeTab(), task: nil)
        XCTAssertEqual(vm.statusIcon, .idle)
    }
}
