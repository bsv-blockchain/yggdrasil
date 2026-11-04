import XCTest
@testable import Yggdrasil

/// The task-picker search box. Every term must match somewhere in the row's
/// fields; a term prefixed with `-` must match nowhere. Quotes hold a phrase
/// together, which labels need — "good first issue" is one label, not three
/// terms.
final class TaskSearchQueryTests: XCTestCase {
    /// A representative row: title, repo, number, state, milestone, two labels.
    private let fields = [
        "Batch validator drops the last block",
        "bsv-blockchain/teranode",
        "#1565",
        "open",
        "v1.2 hardening",
        "P0",
        "good first issue"
    ]

    private func matches(_ query: String, _ fields: [String]? = nil) -> Bool {
        TaskSearchQuery(query).matches(fields ?? self.fields)
    }

    // MARK: - Nothing to filter on

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(matches(""))
    }

    func testWhitespaceOnlyQueryMatchesEverything() {
        XCTAssertTrue(matches("   \t "))
    }

    /// A stray dash while typing `-P0` must not hide every row mid-keystroke.
    func testLoneDashIsIgnored() {
        XCTAssertTrue(matches("-"))
    }

    // MARK: - Positive terms

    func testTermMatchesTheTitle() {
        XCTAssertTrue(matches("validator"))
    }

    func testMatchingIsCaseInsensitive() {
        XCTAssertTrue(matches("VALIDATOR"))
        XCTAssertTrue(matches("p0"))
    }

    func testTermMatchesARepo() {
        XCTAssertTrue(matches("teranode"))
    }

    func testTermMatchesANumber() {
        XCTAssertTrue(matches("1565"))
    }

    func testTermMatchesAState() {
        XCTAssertTrue(matches("open"))
    }

    func testTermMatchesAMilestone() {
        XCTAssertTrue(matches("hardening"))
    }

    func testTermMatchesALabel() {
        XCTAssertTrue(matches("P0"))
    }

    func testTermMatchingNothingFails() {
        XCTAssertFalse(matches("wireguard"))
    }

    /// Several terms are AND, and they may land in different fields.
    func testAllPositiveTermsMustMatch() {
        XCTAssertTrue(matches("P0 teranode"))
        XCTAssertFalse(matches("P0 nosuchrepo"))
    }

    // MARK: - Negation

    func testNegatedTermExcludesAMatchingRow() {
        XCTAssertFalse(matches("-P0"))
    }

    func testNegatedTermKeepsANonMatchingRow() {
        XCTAssertTrue(matches("-P1"))
    }

    func testPositiveAndNegatedTermsCombine() {
        XCTAssertTrue(matches("teranode -P1"))
        XCTAssertFalse(matches("teranode -P0"))
    }

    func testNegationAppliesToEveryField() {
        XCTAssertFalse(matches("-validator"), "a negated term matches the title too")
        XCTAssertFalse(matches("-hardening"), "…and the milestone")
        XCTAssertFalse(matches("-open"), "…and the state")
    }

    func testSeveralNegatedTerms() {
        XCTAssertTrue(matches("-P1 -P2"))
        XCTAssertFalse(matches("-P1 -P0"))
    }

    // MARK: - Quoted phrases

    func testQuotedPhraseMatchesALabelWithSpaces() {
        XCTAssertTrue(matches("\"good first issue\""))
    }

    func testNegatedQuotedPhraseExcludes() {
        XCTAssertFalse(matches("-\"good first issue\""))
    }

    /// Without quotes the words are separate terms, so a phrase that only
    /// exists split across fields still matches — that's AND, not a phrase.
    func testUnquotedWordsAreSeparateTerms() {
        XCTAssertTrue(matches("good first issue"))
        XCTAssertFalse(matches("\"first good issue\""))
    }

    func testQuotedPhraseCombinesWithOtherTerms() {
        XCTAssertTrue(matches("teranode \"good first issue\" -P1"))
        XCTAssertFalse(matches("teranode \"good first issue\" -P0"))
    }

    /// An unterminated quote is what the box looks like halfway through typing
    /// one; take the rest of the string rather than dropping the term.
    func testUnterminatedQuoteTakesTheRest() {
        XCTAssertTrue(matches("\"good first"))
        XCTAssertFalse(matches("\"good second"))
    }

    // MARK: - Rows missing the optional fields

    func testRowWithNoLabelsOrMilestoneStillMatchesOnTitle() {
        let bare = ["Some title", "owner/repo", "#1", "open"]
        XCTAssertTrue(matches("title", bare))
        XCTAssertFalse(matches("P0", bare))
        XCTAssertTrue(matches("-P0", bare), "nothing to exclude on, so it stays")
    }
}
