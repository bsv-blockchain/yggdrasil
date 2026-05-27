import XCTest
@testable import Yggdrasil

/// Quick checks for the review-mode plumbing — branch-name parsing +
/// TaskPickerMode.branchName() + isReviewBranch detector.
final class ReviewPickerTests: XCTestCase {
    func test_parsePRNumber_acceptsReviewPrefixes() {
        XCTAssertEqual(NewTabSheet.parsePRNumber("review-pr-643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("REVIEW-PR-643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("review-pr/643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("review-issue-12"), 12)
    }

    func test_isReviewBranch() {
        XCTAssertTrue(NewTabSheet.isReviewBranch("review-pr-643"))
        XCTAssertTrue(NewTabSheet.isReviewBranch("Review-PR-12"))
        XCTAssertFalse(NewTabSheet.isReviewBranch("pr-643"))
        XCTAssertFalse(NewTabSheet.isReviewBranch("feat/foo"))
    }

    func test_taskPickerMode_branchNameAgentPrefixed() {
        let task = YggdrasilTask(
            id: 1, repoID: 1, type: .pullRequest, number: 643, title: "t",
            body: nil, state: .open, authorLogin: "a", githubURL: "u", apiURL: "u",
            createdAt: Date(), updatedAt: Date(), lastSyncedAt: Date(), etag: nil
        )
        XCTAssertEqual(TaskPickerMode.assigned.branchName(for: task, agentName: "Claude"), "claude-pr-643")
        XCTAssertEqual(TaskPickerMode.review.branchName(for: task, agentName: "Codex"), "codex-review-pr-643")
        XCTAssertEqual(
            TaskPickerMode.assigned.branchName(for: task, agentName: "GitHub Copilot"),
            "github-copilot-pr-643"
        )
    }

    func test_agentSlug_normalisation() {
        XCTAssertEqual(TaskPickerMode.agentSlug("Claude"), "claude")
        XCTAssertEqual(TaskPickerMode.agentSlug("GitHub Copilot"), "github-copilot")
        XCTAssertEqual(TaskPickerMode.agentSlug("  Codex  "), "codex")
        XCTAssertEqual(TaskPickerMode.agentSlug("Grok-4"), "grok-4")
        XCTAssertEqual(TaskPickerMode.agentSlug(""), "")
    }

    func test_parsePRNumber_acceptsAgentPrefixes() {
        XCTAssertEqual(NewTabSheet.parsePRNumber("claude-pr-643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("codex-issue-12"), 12)
        XCTAssertEqual(NewTabSheet.parsePRNumber("github-copilot-pr-643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("claude-review-pr-948"), 948)
    }

    func test_parsePRNumber_rejectsRunOnPrefixes() {
        // "pr-643" embedded mid-word — preceded by a letter, not start-of-string
        // or "-" — should NOT match.
        XCTAssertNil(NewTabSheet.parsePRNumber("looppr-643"))
        XCTAssertNil(NewTabSheet.parsePRNumber("xissue-12"))
    }

    func test_isReviewBranch_handlesAgentPrefix() {
        XCTAssertTrue(NewTabSheet.isReviewBranch("claude-review-pr-948"))
        XCTAssertTrue(NewTabSheet.isReviewBranch("codex-review-pr-948"))
        XCTAssertFalse(NewTabSheet.isReviewBranch("claude-pr-643"))
    }
}
