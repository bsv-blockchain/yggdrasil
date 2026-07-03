import Foundation
import XCTest
@testable import Yggdrasil

@MainActor
final class GitHubURLResolutionTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 0)

    private func task(_ type: YggdrasilTask.Kind, number: Int) -> YggdrasilTask {
        let path = type == .pullRequest ? "pull" : "issues"
        return YggdrasilTask(
            id: Int64(number), repoID: 1, type: type, number: number, title: "t",
            body: nil, state: .open, authorLogin: "me",
            githubURL: "https://github.com/o/r/\(path)/\(number)",
            apiURL: "", createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
            etag: nil, labelsJSON: "[]", milestoneTitle: nil
        )
    }

    private func repo() -> Repo {
        Repo(id: 1, owner: "o", name: "r", defaultBranch: "main", localMainPath: nil, addedAt: epoch)
    }

    /// A fork whose issues/PRs live in the upstream (source) repo.
    private func forkRepo() -> Repo {
        Repo(
            id: 1, owner: "freemans13", name: "teranode",
            defaultBranch: "main", localMainPath: nil, addedAt: epoch,
            upstreamOwner: "bsv-blockchain", upstreamName: "teranode"
        )
    }

    private func resolve(
        primary: YggdrasilTask? = nil,
        linkedPR: YggdrasilTask? = nil,
        repo: Repo? = nil,
        branch: String = "scratch"
    ) -> String? {
        GitHubSubPane.resolveURL(
            primaryTask: primary, linkedPR: linkedPR, repo: repo, branchName: branch
        )?.absoluteString
    }

    func testLinkedPRWinsOverIssue() {
        let url = resolve(primary: task(.issue, number: 1001), linkedPR: task(.pullRequest, number: 1042), repo: repo())
        XCTAssertEqual(url, "https://github.com/o/r/pull/1042")
    }

    func testPROnlyTabOpensPR() {
        XCTAssertEqual(resolve(primary: task(.pullRequest, number: 655), repo: repo()),
                       "https://github.com/o/r/pull/655")
    }

    func testIssueTabWithNoPROpensIssue() {
        XCTAssertEqual(resolve(primary: task(.issue, number: 1001), repo: repo()),
                       "https://github.com/o/r/issues/1001")
    }

    func testAdHocTabOpensRepoHome() {
        XCTAssertEqual(resolve(repo: repo(), branch: "scratch"), "https://github.com/o/r")
    }

    func testNoRepoYieldsNil() {
        XCTAssertNil(resolve(repo: nil, branch: "scratch"))
    }

    func testUnsyncedPRBranchSynthesizesPRURL() {
        XCTAssertEqual(resolve(repo: repo(), branch: "claude-pr-655"),
                       "https://github.com/o/r/pull/655")
    }

    func testUnsyncedIssueBranchSynthesizesIssueURL() {
        XCTAssertEqual(resolve(repo: repo(), branch: "issue-1001"),
                       "https://github.com/o/r/issues/1001")
    }

    func testForkUnsyncedIssueBranchSynthesizesUpstreamIssueURL() {
        // A fork carries no issues of its own; synthesize against the upstream.
        XCTAssertEqual(resolve(repo: forkRepo(), branch: "issue-1001"),
                       "https://github.com/bsv-blockchain/teranode/issues/1001")
    }

    func testForkUnsyncedPRBranchSynthesizesUpstreamPRURL() {
        // PR numbers are per base repo, so a fork's pr-N points upstream.
        XCTAssertEqual(resolve(repo: forkRepo(), branch: "claude-pr-655"),
                       "https://github.com/bsv-blockchain/teranode/pull/655")
    }

    func testForkSyncedIssueTaskOpensUpstreamIssue() {
        // Once synced, the issue task carries the upstream html_url, so the pane
        // opens the parent's issue even though the task lives under the fork.
        let upstreamIssue = YggdrasilTask(
            id: 7, repoID: 1, type: .issue, number: 7, title: "t", body: nil,
            state: .open, authorLogin: "me",
            githubURL: "https://github.com/bsv-blockchain/teranode/issues/7",
            apiURL: "", createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
            etag: nil, labelsJSON: "[]", milestoneTitle: nil
        )
        XCTAssertEqual(resolve(primary: upstreamIssue, repo: forkRepo()),
                       "https://github.com/bsv-blockchain/teranode/issues/7")
    }
}
