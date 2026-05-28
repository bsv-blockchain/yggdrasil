@testable import Yggdrasil
import XCTest

/// Pure-logic tests for IssueDetailsPicker's filter helper. Search +
/// tracked-only filtering both live in `filter(rows:search:trackedRepoKeys:
/// trackedOnly:)` so the view body just renders the result.
final class IssueDetailsPickerFilterTests: XCTestCase {
    private func makeRow(owner: String, repo: String, number: Int = 1,
                         title: String = "Sample", milestone: String = "") -> IssueDetailsPicker.Row {
        IssueDetailsPicker.Row(
            id: "\(owner)/\(repo)#\(number)",
            owner: owner,
            repoName: repo,
            number: number,
            title: title,
            state: "open",
            stateSort: 0,
            labels: [],
            milestone: milestone,
            linkedPRNumber: nil,
            linkedPRState: nil,
            reviewState: nil,
            updatedAtSort: Date(),
            updatedAtDisplay: "now",
            htmlURL: "https://github.com/\(owner)/\(repo)/issues/\(number)"
        )
    }

    func test_filter_blankSearch_andTrackedOff_returnsAllRows() {
        let rows = [
            makeRow(owner: "bsv-blockchain", repo: "teranode"),
            makeRow(owner: "untracked-org", repo: "other")
        ]
        let result = IssueDetailsPicker.filter(
            rows: rows, search: "", trackedRepoKeys: ["bsv-blockchain/teranode"],
            trackedOnly: false
        )
        XCTAssertEqual(result.count, 2)
    }

    func test_filter_trackedOn_dropsUntrackedRepoRows() {
        let rows = [
            makeRow(owner: "bsv-blockchain", repo: "teranode"),
            makeRow(owner: "untracked-org", repo: "other")
        ]
        let result = IssueDetailsPicker.filter(
            rows: rows, search: "", trackedRepoKeys: ["bsv-blockchain/teranode"],
            trackedOnly: true
        )
        XCTAssertEqual(result.map(\.repoFull), ["bsv-blockchain/teranode"])
    }

    func test_filter_trackedOn_emptyTrackedSet_returnsEmpty() {
        let rows = [makeRow(owner: "bsv-blockchain", repo: "teranode")]
        let result = IssueDetailsPicker.filter(
            rows: rows, search: "", trackedRepoKeys: [], trackedOnly: true
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_filter_searchAndTrackedCombine() {
        // Search narrows by title, then trackedOnly drops untracked repos.
        let rows = [
            makeRow(owner: "bsv-blockchain", repo: "teranode", title: "Fix crash"),
            makeRow(owner: "bsv-blockchain", repo: "teranode", number: 2, title: "Add tests"),
            makeRow(owner: "untracked-org", repo: "other", title: "Fix typo")
        ]
        let result = IssueDetailsPicker.filter(
            rows: rows, search: "fix", trackedRepoKeys: ["bsv-blockchain/teranode"],
            trackedOnly: true
        )
        XCTAssertEqual(result.map(\.title), ["Fix crash"])
    }

    func test_filter_searchMatchesRepoName() {
        let rows = [
            makeRow(owner: "alpha", repo: "alpha-repo"),
            makeRow(owner: "beta", repo: "beta-repo")
        ]
        let result = IssueDetailsPicker.filter(
            rows: rows, search: "alpha", trackedRepoKeys: [], trackedOnly: false
        )
        XCTAssertEqual(result.map(\.repoFull), ["alpha/alpha-repo"])
    }
}
