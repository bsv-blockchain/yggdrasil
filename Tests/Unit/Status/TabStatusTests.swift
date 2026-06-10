import XCTest
@testable import Yggdrasil

final class TabStatusTests: XCTestCase {
    private func make(
        claude: ClaudeState = .idle,
        git: GitState = GitState(dirty: false, remote: .noRemote),
        github: GitHubAggregate = .init(ciState: nil, unread: 0)
    ) -> TabStatus {
        TabStatus.aggregate(claude: claude, git: git, github: github)
    }

    // MARK: - Priority (errored > awaiting_input > CI failing > dirty > unread > running > idle)

    func testErroredBeatsEverything() {
        let status = make(
            claude: .errored,
            git: GitState(dirty: true, remote: .noRemote),
            github: .init(ciState: "FAILURE", unread: 5)
        )
        XCTAssertEqual(status.icon, .errored)
    }

    func testAwaitingInputBeatsCIDirtyUnread() {
        let status = make(
            claude: .awaitingInput,
            git: GitState(dirty: true, remote: .noRemote),
            github: .init(ciState: "FAILURE", unread: 5)
        )
        XCTAssertEqual(status.icon, .awaitingInput)
    }

    func testCIFailingBeatsDirtyUnread() {
        let status = make(
            claude: .running,
            git: GitState(dirty: true, remote: .noRemote),
            github: .init(ciState: "FAILURE", unread: 5)
        )
        XCTAssertEqual(status.icon, .ciFailing)
    }

    func testDirtyBeatsUnreadAndRunning() {
        let status = make(
            claude: .running,
            git: GitState(dirty: true, remote: .noRemote),
            github: .init(ciState: "SUCCESS", unread: 5)
        )
        XCTAssertEqual(status.icon, .dirty)
    }

    func testUnreadBeatsRunningAndIdle() {
        let status = make(
            claude: .running,
            git: GitState(dirty: false, remote: .noRemote),
            github: .init(ciState: "SUCCESS", unread: 1)
        )
        XCTAssertEqual(status.icon, .unread)
    }

    func testRunningBeatsIdle() {
        let status = make(claude: .running)
        XCTAssertEqual(status.icon, .running)
    }

    func testIdleIsDefault() {
        let status = make()
        XCTAssertEqual(status.icon, .idle)
    }

    // MARK: - Unread badge dot

    func testUnreadDotShownWhenUnreadCountIsPositive() {
        let status = make(github: .init(ciState: nil, unread: 3))
        XCTAssertTrue(status.showsUnreadBadgeDot)
    }

    func testNoDotWhenUnreadIsZero() {
        let status = make()
        XCTAssertFalse(status.showsUnreadBadgeDot)
    }

    // MARK: - Tooltip lines

    func testTooltipIncludesAllSignals() {
        let status = make(
            claude: .running,
            git: GitState(dirty: true, remote: .ahead(2, behind: 1)),
            github: .init(ciState: "FAILURE", unread: 3)
        )
        let lines = status.tooltipLines
        XCTAssertTrue(lines.contains(where: { $0.contains("Claude") && $0.contains("running") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("dirty") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("2 ahead") || $0.contains("ahead 2") }))
        XCTAssertTrue(lines.contains(where: { $0.contains("1 behind") || $0.contains("behind 1") }))
        XCTAssertTrue(lines.contains(where: { $0.lowercased().contains("ci") && $0.contains("FAILURE") }))
        XCTAssertTrue(lines.contains(where: { $0.lowercased().contains("unread") && $0.contains("3") }))
    }

    // MARK: - Review state

    func testReviewStatePassesThrough() {
        let status = make(github: .init(ciState: "SUCCESS", reviewState: "CHANGES_REQUESTED", unread: 0))
        XCTAssertEqual(status.reviewState, "CHANGES_REQUESTED")
    }

    func testReviewStateDoesNotDisplaceWorkIcon() {
        // An approved PR is still "idle" work-wise — the review shows as a
        // separate dot, never as the row's work-state icon.
        let status = make(github: .init(ciState: "SUCCESS", reviewState: "APPROVED", unread: 0))
        XCTAssertEqual(status.icon, .idle)
    }

    func testTooltipIncludesReviewLabel() {
        let status = make(github: .init(ciState: nil, reviewState: "APPROVED", unread: 0))
        XCTAssertTrue(status.tooltipLines.contains("Review: Approved"))
    }

    func testReviewLabelMapping() {
        XCTAssertEqual(TabStatus.reviewLabel("APPROVED"), "Approved")
        XCTAssertEqual(TabStatus.reviewLabel("CHANGES_REQUESTED"), "Changes requested")
        XCTAssertEqual(TabStatus.reviewLabel("REVIEW_REQUIRED"), "Review required")
        XCTAssertNil(TabStatus.reviewLabel(nil))
        XCTAssertNil(TabStatus.reviewLabel(""))
        XCTAssertNil(TabStatus.reviewLabel("COMMENTED"))
    }
}
