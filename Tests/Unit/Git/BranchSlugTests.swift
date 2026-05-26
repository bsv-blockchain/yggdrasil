@testable import Loom
import XCTest

final class BranchSlugTests: XCTestCase {

    func testReplacesSlashesWithDashes() {
        XCTAssertEqual(BranchSlug.slug(for: "feat/foo"), "feat-foo")
        XCTAssertEqual(BranchSlug.slug(for: "release/v1.2.3"), "release-v1.2.3")
    }

    func testDropsDisallowedCharacters() {
        // Spec §2.1: keep [a-zA-Z0-9._-], drop the rest.
        XCTAssertEqual(BranchSlug.slug(for: "feat/foo bar"), "feat-foo-bar")
        XCTAssertEqual(BranchSlug.slug(for: "fix#123: do thing"), "fix123-do-thing")
        XCTAssertEqual(BranchSlug.slug(for: "spaces in name"), "spaces-in-name")
    }

    func testPreservesAllowedPunctuation() {
        XCTAssertEqual(BranchSlug.slug(for: "v1.2.3"), "v1.2.3")
        XCTAssertEqual(BranchSlug.slug(for: "feat_foo"), "feat_foo")
        XCTAssertEqual(BranchSlug.slug(for: "feat-foo"), "feat-foo")
    }

    func testEmptyAndSingleSlashEdgeCases() {
        XCTAssertEqual(BranchSlug.slug(for: ""), "")
        XCTAssertEqual(BranchSlug.slug(for: "/"), "-")
        XCTAssertEqual(BranchSlug.slug(for: "/main"), "-main")
    }

    func testCollapsesRunsOfDashes() {
        // " " becomes "-", then " // " becomes "----" which is ugly; collapse to one.
        XCTAssertEqual(BranchSlug.slug(for: "feat / foo"), "feat-foo")
        XCTAssertEqual(BranchSlug.slug(for: "feat//foo"), "feat-foo")
    }

    func testTruncatesLongNamesTo60CharsWithHashSuffix() {
        // 80-char input → 60-char output where the last ~8 chars are a hash for uniqueness.
        let longBranch = String(repeating: "a", count: 80)
        let result = BranchSlug.slug(for: longBranch)
        XCTAssertEqual(result.count, 60)
        // Different long branches must produce different slugs (uniqueness via hash).
        let longBranch2 = String(repeating: "b", count: 80)
        XCTAssertNotEqual(result, BranchSlug.slug(for: longBranch2))
    }

    func testShortNamesNotTruncated() {
        // 59 chars: untouched.
        let s = String(repeating: "a", count: 59)
        XCTAssertEqual(BranchSlug.slug(for: s), s)
        // 60 chars exactly: untouched.
        let s60 = String(repeating: "a", count: 60)
        XCTAssertEqual(BranchSlug.slug(for: s60), s60)
    }

    func testStableForSameInput() {
        // Truncation hash must be deterministic across calls.
        let longBranch = String(repeating: "z", count: 100)
        XCTAssertEqual(BranchSlug.slug(for: longBranch), BranchSlug.slug(for: longBranch))
    }
}
