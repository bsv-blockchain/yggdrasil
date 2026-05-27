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

    func test_taskPickerMode_branchNameProducesReviewPrefix() {
        let task = YggdrasilTask(
            id: 1, repoID: 1, type: .pullRequest, number: 643, title: "t",
            body: nil, state: .open, authorLogin: "a", githubURL: "u", apiURL: "u",
            createdAt: Date(), updatedAt: Date(), lastSyncedAt: Date(), etag: nil
        )
        XCTAssertEqual(TaskPickerMode.assigned.branchName(for: task), "pr-643")
        XCTAssertEqual(TaskPickerMode.review.branchName(for: task), "review-pr-643")
    }
}
