import XCTest
@testable import Yggdrasil

/// Verifies the branch-name → PR-number heuristic used by NewTabSheet to
/// auto-link a new tab to a synced GitHub task.
final class NewTabSheetParseTests: XCTestCase {
    func test_parsePRNumber_handlesCommonPrefixes() {
        XCTAssertEqual(NewTabSheet.parsePRNumber("pr-643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("PR-643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("pr/643"), 643)
        XCTAssertEqual(NewTabSheet.parsePRNumber("issue-12"), 12)
        XCTAssertEqual(NewTabSheet.parsePRNumber("issue/12"), 12)
        XCTAssertEqual(NewTabSheet.parsePRNumber("#643"), 643)
    }

    func test_parsePRNumber_rejectsFreeformBranches() {
        XCTAssertNil(NewTabSheet.parsePRNumber("feat/something"))
        XCTAssertNil(NewTabSheet.parsePRNumber("main"))
        XCTAssertNil(NewTabSheet.parsePRNumber("pr-abc"))
        XCTAssertNil(NewTabSheet.parsePRNumber(""))
        XCTAssertNil(NewTabSheet.parsePRNumber("pr-"))
    }

    func test_parsePRNumber_trimsWhitespace() {
        XCTAssertEqual(NewTabSheet.parsePRNumber("  pr-643  "), 643)
    }

    // MARK: - interpretBranchInput

    func test_interpret_githubPRURL() {
        let out = NewTabSheet.interpretBranchInput("https://github.com/bsv-blockchain/teranode/pull/643")
        XCTAssertEqual(out.branch, "pr-643")
        XCTAssertEqual(out.repoSlug, "bsv-blockchain/teranode")
    }

    func test_interpret_githubIssueURL() {
        let out = NewTabSheet.interpretBranchInput("https://github.com/bsv-blockchain/teranode/issues/12")
        XCTAssertEqual(out.branch, "issue-12")
        XCTAssertEqual(out.repoSlug, "bsv-blockchain/teranode")
    }

    func test_interpret_bareNumberDefaultsToPR() {
        XCTAssertEqual(NewTabSheet.interpretBranchInput("643").branch, "pr-643")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("#12").branch, "pr-12")
    }

    func test_interpret_freeFormPassesThrough() {
        XCTAssertEqual(NewTabSheet.interpretBranchInput("feat/foo").branch, "feat/foo")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("pr-643").branch, "pr-643")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("claude-pr-643").branch, "claude-pr-643")
    }

    func test_interpret_doesntSetRepoSlugForFreeForm() {
        XCTAssertNil(NewTabSheet.interpretBranchInput("feat/foo").repoSlug)
        XCTAssertNil(NewTabSheet.interpretBranchInput("643").repoSlug)
    }

    func test_interpret_unrelatedURLPassesThrough() {
        XCTAssertEqual(
            NewTabSheet.interpretBranchInput("https://example.com/something").branch,
            "https://example.com/something"
        )
    }
}
