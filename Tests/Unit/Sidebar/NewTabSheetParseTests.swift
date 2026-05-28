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

    func test_parsePRNumber_handlesSeparatorlessShorthand() {
        // Legacy tabs created with separator-less branch names ("claude-pr828")
        // should still link back to their PR task so the sidebar #xxx badge
        // appears.
        XCTAssertEqual(NewTabSheet.parsePRNumber("pr828"), 828)
        XCTAssertEqual(NewTabSheet.parsePRNumber("claude-pr828"), 828)
        XCTAssertEqual(NewTabSheet.parsePRNumber("issue7"), 7)
        XCTAssertEqual(NewTabSheet.parsePRNumber("claude-issue7"), 7)
        XCTAssertEqual(NewTabSheet.parsePRNumber("review-pr828"), 828)
        XCTAssertEqual(NewTabSheet.parsePRNumber("claude-review-pr828"), 828)
    }

    func test_parsePRNumber_rejectsPRLikeButNotNumericTails() {
        // Don't false-match these — they look like PR refs but aren't.
        XCTAssertNil(NewTabSheet.parsePRNumber("prerelease"))
        XCTAssertNil(NewTabSheet.parsePRNumber("issuer"))
        XCTAssertNil(NewTabSheet.parsePRNumber("pr-828-fix"))
        XCTAssertNil(NewTabSheet.parsePRNumber("claude-prerelease"))
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

    // MARK: - Separator-less PR/issue shorthands

    func test_interpret_normalisesSeparatorlessPR() {
        // "pr828" — no hyphen — should normalise to "pr-828" so the
        // confirm() flow takes the PR-fetch path instead of branching off
        // main with the user's literal text. (Bug: a worktree was created
        // but the PR was never checked out because parsing missed this.)
        XCTAssertEqual(NewTabSheet.interpretBranchInput("pr828").branch, "pr-828")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("PR828").branch, "pr-828")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("issue7").branch, "issue-7")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("ISSUE7").branch, "issue-7")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("review-pr12").branch, "review-pr-12")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("review-issue99").branch, "review-issue-99")
    }

    func test_interpret_separatorlessShorthandTrimsWhitespace() {
        XCTAssertEqual(NewTabSheet.interpretBranchInput("  pr828  ").branch, "pr-828")
    }

    func test_interpret_doesNotMangleFreeFormBranchesThatLookSimilar() {
        // "prerelease" must not become "pr-erelease" — only literal pr<digits>
        // and issue<digits> with nothing else after.
        XCTAssertEqual(NewTabSheet.interpretBranchInput("prerelease").branch, "prerelease")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("issuer").branch, "issuer")
        XCTAssertEqual(NewTabSheet.interpretBranchInput("pr-828-fix").branch, "pr-828-fix")
    }
}
