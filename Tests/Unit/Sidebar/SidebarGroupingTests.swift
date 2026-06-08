import XCTest
@testable import Yggdrasil

final class SidebarGroupingTests: XCTestCase {
    private func makeTab(id: Int64, branch: String) -> YggdrasilTab {
        YggdrasilTab(
            id: id, taskID: nil, codingAgentID: nil,
            position: Int(id),
            branchName: branch, worktreePath: "/tmp/\(branch)",
            lastMainView: .agent,
            createdAt: Date(timeIntervalSince1970: 0),
            lastActiveAt: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeRepo(id: Int64, owner: String, name: String) -> Repo {
        Repo(
            id: id, owner: owner, name: name,
            defaultBranch: "main", localMainPath: nil,
            addedAt: Date(timeIntervalSince1970: 0)
        )
    }

    func testEmptyInputYieldsNoGroups() {
        let groups = SidebarGrouping.groupByRepo(tabs: [], repoByTabID: [:])
        XCTAssertTrue(groups.isEmpty)
    }

    func testSingleRepoSingleGroup() {
        let tab1 = makeTab(id: 1, branch: "a")
        let tab2 = makeTab(id: 2, branch: "b")
        let repo = makeRepo(id: 10, owner: "acme", name: "widget")
        let groups = SidebarGrouping.groupByRepo(
            tabs: [tab1, tab2],
            repoByTabID: [1: repo, 2: repo]
        )
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].title, "acme/widget")
        XCTAssertEqual(groups[0].tabs.map(\.branchName), ["a", "b"])
    }

    func testMultipleReposGroupedAndOrderedByFirstAppearance() {
        let tabA1 = makeTab(id: 1, branch: "a1")
        let tabB1 = makeTab(id: 2, branch: "b1")
        let tabA2 = makeTab(id: 3, branch: "a2")
        let tabB2 = makeTab(id: 4, branch: "b2")
        let repoA = makeRepo(id: 10, owner: "acme", name: "alpha")
        let repoB = makeRepo(id: 20, owner: "acme", name: "beta")
        let groups = SidebarGrouping.groupByRepo(
            tabs: [tabA1, tabB1, tabA2, tabB2],
            repoByTabID: [1: repoA, 2: repoB, 3: repoA, 4: repoB]
        )
        XCTAssertEqual(groups.map(\.title), ["acme/alpha", "acme/beta"])
        XCTAssertEqual(groups[0].tabs.map(\.branchName), ["a1", "a2"])
        XCTAssertEqual(groups[1].tabs.map(\.branchName), ["b1", "b2"])
    }

    func testUnresolvedRepoFallsIntoOtherGroupAtEnd() {
        let tabA = makeTab(id: 1, branch: "a")
        let tabOrphan = makeTab(id: 2, branch: "orphan")
        let tabA2 = makeTab(id: 3, branch: "a2")
        let repoA = makeRepo(id: 10, owner: "acme", name: "alpha")
        let groups = SidebarGrouping.groupByRepo(
            tabs: [tabA, tabOrphan, tabA2],
            repoByTabID: [1: repoA, 3: repoA]
        )
        XCTAssertEqual(groups.map(\.title), ["acme/alpha", "Other"])
        XCTAssertEqual(groups[0].tabs.map(\.branchName), ["a", "a2"])
        XCTAssertEqual(groups[1].tabs.map(\.branchName), ["orphan"])
    }

    func testDropAllowedWhenGroupingOffAlwaysTrue() {
        let repoA = makeRepo(id: 10, owner: "acme", name: "alpha")
        let repoB = makeRepo(id: 20, owner: "acme", name: "beta")
        XCTAssertTrue(SidebarGrouping.dropAllowed(
            sourceTabID: 1, targetTabID: 2,
            repoByTabID: [1: repoA, 2: repoB],
            grouped: false
        ))
    }

    func testDropAllowedSameRepoWhenGrouped() {
        let repoA = makeRepo(id: 10, owner: "acme", name: "alpha")
        XCTAssertTrue(SidebarGrouping.dropAllowed(
            sourceTabID: 1, targetTabID: 2,
            repoByTabID: [1: repoA, 2: repoA],
            grouped: true
        ))
    }

    func testDropRejectedCrossRepoWhenGrouped() {
        let repoA = makeRepo(id: 10, owner: "acme", name: "alpha")
        let repoB = makeRepo(id: 20, owner: "acme", name: "beta")
        XCTAssertFalse(SidebarGrouping.dropAllowed(
            sourceTabID: 1, targetTabID: 2,
            repoByTabID: [1: repoA, 2: repoB],
            grouped: true
        ))
    }

    func testDropAllowedBothInOtherBucketWhenGrouped() {
        XCTAssertTrue(SidebarGrouping.dropAllowed(
            sourceTabID: 1, targetTabID: 2,
            repoByTabID: [:],
            grouped: true
        ))
    }

    func testDropRejectedRepoVsOtherWhenGrouped() {
        let repoA = makeRepo(id: 10, owner: "acme", name: "alpha")
        XCTAssertFalse(SidebarGrouping.dropAllowed(
            sourceTabID: 1, targetTabID: 2,
            repoByTabID: [1: repoA],
            grouped: true
        ))
    }
}
