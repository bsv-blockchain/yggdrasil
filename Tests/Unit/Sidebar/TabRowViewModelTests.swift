import Foundation
import XCTest
@testable import Yggdrasil

final class TabRowViewModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeTab(
        id: Int64 = 1,
        taskID: Int64? = nil,
        branch: String = "feat/foo",
        worktree: String = "/Users/sigi/code/.worktrees/feat-foo"
    ) -> YggdrasilTab {
        YggdrasilTab(
            id: id, taskID: taskID, codingAgentID: nil, position: 0,
            branchName: branch, worktreePath: worktree,
            lastMainView: .agent, createdAt: now, lastActiveAt: now
        )
    }

    private func makeTask(
        type: YggdrasilTask.Kind = .pullRequest,
        number: Int = 655,
        title: String = "Add diff engine"
    ) -> YggdrasilTask {
        YggdrasilTask(
            id: 1, repoID: 1, type: type, number: number, title: title,
            body: nil, state: .open, authorLogin: "sigi",
            githubURL: "https://github.com/o/r/pull/\(number)",
            apiURL: "https://api.github.com/repos/o/r/pulls/\(number)",
            createdAt: now, updatedAt: now, lastSyncedAt: now, etag: nil
        )
    }

    func testRowWithTaskUsesTaskTitle() {
        let model = TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(title: "Hello"))
        XCTAssertEqual(model.titleLine, "Hello")
    }

    func testIssueTabWithLinkedPRShowsBothBadges() {
        let model = TabRowViewModel(
            tab: makeTab(taskID: 1),
            task: makeTask(type: .issue, number: 1001),
            prTask: makeTask(type: .pullRequest, number: 1042)
        )
        XCTAssertEqual(model.trailingBadge, .issueNumber(1001))
        XCTAssertEqual(model.secondaryBadge, .prNumber(1042))
    }

    func testIssueTabWithoutLinkedPRHasNoSecondaryBadge() {
        let model = TabRowViewModel(
            tab: makeTab(taskID: 1),
            task: makeTask(type: .issue, number: 1001),
            prTask: nil
        )
        XCTAssertEqual(model.trailingBadge, .issueNumber(1001))
        XCTAssertEqual(model.secondaryBadge, .none)
    }

    func testPROnlyTabHasNoSecondaryBadge() {
        // A PR-only tab shouldn't sprout a second badge even if a PR task is
        // somehow passed — the secondary is reserved for issue+PR pairing.
        let model = TabRowViewModel(
            tab: makeTab(taskID: 1),
            task: makeTask(type: .pullRequest, number: 655),
            prTask: makeTask(type: .pullRequest, number: 1042)
        )
        XCTAssertEqual(model.trailingBadge, .prNumber(655))
        XCTAssertEqual(model.secondaryBadge, .none)
    }

    func testRowWithoutTaskFallsBackToBranchName() {
        let model = TabRowViewModel(tab: makeTab(taskID: nil, branch: "scratch"), task: nil)
        XCTAssertEqual(model.titleLine, "scratch")
    }

    func testBranchLineAlwaysShowsTabBranch() {
        let model = TabRowViewModel(tab: makeTab(branch: "feat/foo"), task: makeTask())
        XCTAssertEqual(model.branchLine, "feat/foo")
    }

    func testShortWorktreePathIsNotTruncated() {
        let model = TabRowViewModel(tab: makeTab(worktree: "/short/path"), task: nil)
        XCTAssertEqual(model.worktreeLine, "/short/path")
    }

    func testLongWorktreePathIsMidEllipsisTruncated() {
        let long = "/Users/sigi/code/work/projects/bsv-blockchain/teranode/.worktrees/feat-some-long-branch-name"
        let model = TabRowViewModel(tab: makeTab(worktree: long), task: nil, maxWorktreeChars: 40)
        XCTAssertLessThanOrEqual(model.worktreeLine.count, 40)
        XCTAssertTrue(model.worktreeLine.contains("…"))
        // Start and end of the original path survive truncation.
        XCTAssertTrue(model.worktreeLine.hasPrefix("/Users"))
        XCTAssertTrue(model.worktreeLine.hasSuffix("branch-name") || model.worktreeLine.hasSuffix("h-name"))
    }

    func testTrailingBadgeForPRIsPRNumber() {
        let model = TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(type: .pullRequest, number: 655))
        guard case let .prNumber(num) = model.trailingBadge else {
            return XCTFail("expected .prNumber, got \(model.trailingBadge)")
        }
        XCTAssertEqual(num, 655)
    }

    func testTrailingBadgeForIssueIsIssueIcon() {
        let model = TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(type: .issue, number: 42))
        guard case let .issueNumber(num) = model.trailingBadge else {
            return XCTFail("expected .issueNumber, got \(model.trailingBadge)")
        }
        XCTAssertEqual(num, 42)
    }

    func testTrailingBadgeForAdHocTabIsNone() {
        let model = TabRowViewModel(tab: makeTab(taskID: nil), task: nil)
        if case .none = model.trailingBadge { /* expected */ } else {
            XCTFail("expected .none, got \(model.trailingBadge)")
        }
    }

    func testStatusIconDefaultsToIdlePlaceholder() {
        // Phase 6 will populate real states. For now the row shows the placeholder.
        let model = TabRowViewModel(tab: makeTab(), task: nil)
        XCTAssertEqual(model.statusIcon, .idle)
    }

    // MARK: - Repo line

    func testRepoLineShownWhenNotGrouped() {
        let model = TabRowViewModel(tab: makeTab(), task: nil, repoName: "acme/widgets", grouped: false)
        XCTAssertEqual(model.repoLine, "acme/widgets")
    }

    func testRepoLineHiddenWhenGrouped() {
        let model = TabRowViewModel(tab: makeTab(), task: nil, repoName: "acme/widgets", grouped: true)
        XCTAssertNil(model.repoLine)
    }

    func testRepoLineNilWhenRepoUnknown() {
        let model = TabRowViewModel(tab: makeTab(), task: nil, repoName: nil, grouped: false)
        XCTAssertNil(model.repoLine)
    }

    // MARK: - Review dot

    private func liveStatus(reviewState: String?) -> TabStatus {
        TabStatus.aggregate(
            claude: .idle,
            git: GitState(dirty: false, remote: .noRemote),
            github: .init(ciState: nil, reviewState: reviewState, unread: 0)
        )
    }

    func testReviewDotMapping() {
        XCTAssertEqual(
            TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(),
                            liveStatus: liveStatus(reviewState: "APPROVED")).reviewDot,
            .approved
        )
        XCTAssertEqual(
            TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(),
                            liveStatus: liveStatus(reviewState: "CHANGES_REQUESTED")).reviewDot,
            .changesRequested
        )
        XCTAssertEqual(
            TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(),
                            liveStatus: liveStatus(reviewState: "REVIEW_REQUIRED")).reviewDot,
            .reviewRequired
        )
    }

    func testNoReviewDotForUnknownOrMissingState() {
        XCTAssertNil(TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(),
                                     liveStatus: liveStatus(reviewState: nil)).reviewDot)
        XCTAssertNil(TabRowViewModel(tab: makeTab(taskID: 1), task: makeTask(),
                                     liveStatus: liveStatus(reviewState: "COMMENTED")).reviewDot)
        XCTAssertNil(TabRowViewModel(tab: makeTab(), task: nil).reviewDot)
    }

    private func liveStatus(reviewActivity: Bool) -> TabStatus {
        TabStatus.aggregate(
            claude: .idle,
            git: GitState(dirty: false, remote: .noRemote),
            github: .init(ciState: nil, unread: 0, hasActivity: reviewActivity)
        )
    }

    func testReviewBranchWithActivityNeedsAttention() {
        let model = TabRowViewModel(
            tab: makeTab(branch: "review-pr-655"), task: makeTask(),
            liveStatus: liveStatus(reviewActivity: true)
        )
        XCTAssertTrue(model.isReview)
        XCTAssertTrue(model.reviewNeedsAttention)
    }

    func testReviewBranchWithoutActivityDoesNotNeedAttention() {
        let model = TabRowViewModel(
            tab: makeTab(branch: "review-pr-655"), task: makeTask(),
            liveStatus: liveStatus(reviewActivity: false)
        )
        XCTAssertTrue(model.isReview)
        XCTAssertFalse(model.reviewNeedsAttention)
    }

    func testNonReviewBranchNeverNeedsAttention() {
        let model = TabRowViewModel(
            tab: makeTab(branch: "feat/foo"), task: makeTask(),
            liveStatus: liveStatus(reviewActivity: true)
        )
        XCTAssertFalse(model.isReview)
        XCTAssertFalse(model.reviewNeedsAttention)
    }

    private func liveStatus(reviewApproved: Bool) -> TabStatus {
        TabStatus.aggregate(
            claude: .idle,
            git: GitState(dirty: false, remote: .noRemote),
            github: .init(ciState: nil, unread: 0, reviewApproved: reviewApproved)
        )
    }

    func testReviewBranchApprovedIsApproved() {
        let model = TabRowViewModel(
            tab: makeTab(branch: "review-pr-655"), task: makeTask(),
            liveStatus: liveStatus(reviewApproved: true)
        )
        XCTAssertTrue(model.reviewApproved)
    }

    func testNonReviewBranchNeverApproved() {
        let model = TabRowViewModel(
            tab: makeTab(branch: "feat/foo"), task: makeTask(),
            liveStatus: liveStatus(reviewApproved: true)
        )
        XCTAssertFalse(model.reviewApproved)
    }
}
