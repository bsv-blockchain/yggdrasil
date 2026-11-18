import XCTest
@testable import Yggdrasil

/// The prompt a new review or issue tab's Claude starts with: which template
/// applies, and what it becomes for one PR or issue.
final class StartingPromptTemplateTests: XCTestCase {
    private let review = StartingPrompt.Subject(
        kind: .review, number: 12, url: "https://github.com/acme/widget/pull/12"
    )

    func testTheRepoOverridesTheGlobalWhichOverridesTheDefault() {
        XCTAssertEqual(StartingPrompt.template(.review, repoOverride: nil, global: nil), "/cr {number}")
        XCTAssertEqual(StartingPrompt.template(.issue, repoOverride: nil, global: nil), "/fix-issue {number}")
        XCTAssertEqual(StartingPrompt.template(.review, repoOverride: nil, global: "/review {url}"), "/review {url}")
        XCTAssertEqual(
            StartingPrompt.template(.review, repoOverride: "/mine {number}", global: "/review"),
            "/mine {number}"
        )
    }

    func testAnEmptyTemplateIsOffAtEitherLevel() {
        XCTAssertNil(StartingPrompt.render(
            StartingPrompt.template(.review, repoOverride: nil, global: ""),
            subject: review
        ))
        XCTAssertNil(StartingPrompt.render(
            StartingPrompt.template(.review, repoOverride: "", global: "/cr {number}"), subject: review
        ), "a repo can turn it off when the global one is on")
    }

    func testPlaceholdersComeFromThePRsOwnURL() {
        XCTAssertEqual(StartingPrompt.render("/cr {number}", subject: review), "/cr 12")
        XCTAssertEqual(
            StartingPrompt.render("look at {url} in {repo}", subject: review),
            "look at https://github.com/acme/widget/pull/12 in acme/widget"
        )
        // A fork's tab can carry its upstream's issue: {repo} names where the
        // issue lives, not the tab's repo.
        let upstream = StartingPrompt.Subject(kind: .issue, number: 5, url: "https://github.com/origin/widget/issues/5")
        XCTAssertEqual(
            StartingPrompt.render("/fix-issue {repo}#{number}", subject: upstream),
            "/fix-issue origin/widget#5"
        )
    }

    func testWhitespaceOnlyIsOffAndUnknownPlaceholdersStay() {
        XCTAssertNil(StartingPrompt.render("  \n ", subject: review))
        XCTAssertEqual(StartingPrompt.render("/cr {pr}", subject: review), "/cr {pr}")
    }

    func testAPIAndSheetValuesMapToAChoice() {
        XCTAssertEqual(StartingPrompt.Choice(nil), .template, "left out: the template")
        XCTAssertEqual(StartingPrompt.Choice(""), StartingPrompt.Choice.none, "empty: no prompt")
        XCTAssertEqual(StartingPrompt.Choice("  "), StartingPrompt.Choice.none)
        XCTAssertEqual(StartingPrompt.Choice("go"), .custom("go"))
    }
}
