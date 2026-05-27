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
}
