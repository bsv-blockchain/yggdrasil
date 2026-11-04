import GRDB
import XCTest
@testable import Yggdrasil

/// `repo.pr_repo_id` (v19): where a repo's PRs live, for "Link PR…".
final class RepoPRRepoTests: XCTestCase {
    func testV19PRRepoRoundTripsAndNullsOnDelete() throws {
        let db = try YggdrasilDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let issuesID = try db.queue.write { db -> Int64 in
            var prs = Repo(
                id: nil, owner: "bsv-blockchain", name: "teranode",
                defaultBranch: "main", localMainPath: nil, addedAt: now
            )
            try prs.insert(db)
            var issues = Repo(
                id: nil, owner: "bitcoin-sv", name: "teranode",
                defaultBranch: "main", localMainPath: nil, addedAt: now,
                prRepoID: prs.id
            )
            try issues.insert(db)
            return issues.id!
        }
        let stored = try db.queue.read { db in try Repo.fetchOne(db, key: issuesID) }
        XCTAssertNotNil(stored?.prRepoID)

        // Untracking the PR repo drops the setting instead of failing the delete.
        try db.queue.write { db in
            _ = try Repo.filter(Column("owner") == "bsv-blockchain").deleteAll(db)
        }
        let after = try db.queue.read { db in try Repo.fetchOne(db, key: issuesID) }
        XCTAssertNotNil(after)
        XCTAssertNil(after?.prRepoID)
    }

    func testPRRepoResolvesConfiguredRepoElseSelf() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let prs = Repo(id: 1, owner: "bsv-blockchain", name: "teranode",
                       defaultBranch: "main", localMainPath: nil, addedAt: now)
        let issues = Repo(id: 2, owner: "bitcoin-sv", name: "teranode",
                          defaultBranch: "main", localMainPath: nil, addedAt: now,
                          prRepoID: 1)
        let dangling = Repo(id: 3, owner: "x", name: "y",
                            defaultBranch: "main", localMainPath: nil, addedAt: now,
                            prRepoID: 99)
        let all = [prs, issues, dangling]
        XCTAssertEqual(issues.prRepo(among: all), prs)
        XCTAssertEqual(prs.prRepo(among: all), prs)
        XCTAssertEqual(dangling.prRepo(among: all), dangling)
    }
}
