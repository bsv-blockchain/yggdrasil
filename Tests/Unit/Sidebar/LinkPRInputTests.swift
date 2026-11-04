import XCTest
@testable import Yggdrasil

/// "Link PR…" input → which repo + PR number to import. A bare number means
/// the default PR repo; a PR URL or `owner/repo#N` names the repo explicitly
/// (cross-repo links, e.g. a private issue repo whose PRs live in a public one).
final class LinkPRInputTests: XCTestCase {
    private typealias Target = SidebarActions.LinkPRTarget

    private func parse(_ raw: String) -> Target? {
        SidebarActions.parseLinkPRInput(raw, defaultOwner: "bsv-blockchain", defaultName: "teranode")
    }

    func test_bareNumber_usesDefaultRepo() {
        XCTAssertEqual(parse("123"), Target(owner: "bsv-blockchain", name: "teranode", number: 123))
        XCTAssertEqual(parse("  #123 "), Target(owner: "bsv-blockchain", name: "teranode", number: 123))
    }

    func test_branchStyleInput_usesDefaultRepo() {
        // Pre-existing behaviour: the dialog accepted pr-N style input.
        XCTAssertEqual(parse("pr-828"), Target(owner: "bsv-blockchain", name: "teranode", number: 828))
    }

    func test_prURL_usesRepoFromURL() {
        XCTAssertEqual(
            parse("https://github.com/bitcoin-sv/other/pull/42"),
            Target(owner: "bitcoin-sv", name: "other", number: 42)
        )
        XCTAssertEqual(
            parse("https://github.com/bitcoin-sv/other/pull/42/files"),
            Target(owner: "bitcoin-sv", name: "other", number: 42)
        )
    }

    func test_ownerRepoHashNumber_usesNamedRepo() {
        XCTAssertEqual(parse("bitcoin-sv/other#7"), Target(owner: "bitcoin-sv", name: "other", number: 7))
        XCTAssertEqual(parse("org/repo.name_x#7"), Target(owner: "org", name: "repo.name_x", number: 7))
    }

    func test_issueURL_isRejected() {
        XCTAssertNil(parse("https://github.com/bitcoin-sv/teranode/issues/42"))
    }

    func test_junk_isRejected() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("feat/something"))
        XCTAssertNil(parse("owner/repo#"))
        XCTAssertNil(parse("owner/repo#abc"))
        XCTAssertNil(parse("owner/repo#+5"))
        XCTAssertNil(parse("/repo#5"))
        XCTAssertNil(parse("owner/#5"))
        XCTAssertNil(parse("a/b/c#5"))
        XCTAssertNil(parse("owner repo/x#5"))
    }

    func test_defaultPRRepo_prefersTaskRepoOverPathRepo() {
        // Two tracked repos sharing one checkout: the worktree path resolves
        // to the first, but the tab's issue lives in the second, whose PRs are
        // configured to live in the first.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let publicRepo = Repo(id: 1, owner: "bsv-blockchain", name: "teranode",
                              defaultBranch: "main", localMainPath: "/x", addedAt: now)
        let issueRepo = Repo(id: 10, owner: "bitcoin-sv", name: "teranode",
                             defaultBranch: "main", localMainPath: "/x", addedAt: now,
                             prRepoID: 1)
        let other = Repo(id: 20, owner: "o", name: "other",
                         defaultBranch: "main", localMainPath: "/x", addedAt: now)
        let configured = Repo(id: 30, owner: "bitcoin-sv", name: "configured",
                              defaultBranch: "main", localMainPath: "/x", addedAt: now,
                              prRepoID: 20)
        let repos = [publicRepo, issueRepo, other, configured]

        // Task repo wins over the path match and its setting is applied.
        XCTAssertEqual(
            SidebarActions.defaultPRRepo(taskRepoID: 30, pathRepo: publicRepo, repos: repos),
            other
        )
        XCTAssertEqual(
            SidebarActions.defaultPRRepo(taskRepoID: 10, pathRepo: publicRepo, repos: repos),
            publicRepo
        )
        // Ad-hoc tab (no task): path repo and its setting.
        XCTAssertEqual(
            SidebarActions.defaultPRRepo(taskRepoID: nil, pathRepo: configured, repos: repos),
            other
        )
        // Unknown task repo id: fall back to the path repo.
        XCTAssertEqual(
            SidebarActions.defaultPRRepo(taskRepoID: 999, pathRepo: publicRepo, repos: repos),
            publicRepo
        )
    }

    func test_trackedRepo_matchesCaseInsensitively() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let stored = Repo(id: 1, owner: "BSV-Blockchain", name: "Teranode",
                          defaultBranch: "main", localMainPath: nil, addedAt: now)
        XCTAssertEqual(
            SidebarActions.trackedRepo(for: Target(owner: "bsv-blockchain", name: "teranode", number: 1),
                                       in: [stored]),
            stored
        )
        XCTAssertNil(
            SidebarActions.trackedRepo(for: Target(owner: "bsv-blockchain", name: "other", number: 1),
                                       in: [stored])
        )
    }

    func test_display() {
        XCTAssertEqual(Target(owner: "o", name: "r", number: 5).display, "o/r#5")
    }
}
