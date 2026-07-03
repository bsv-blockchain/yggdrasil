import Foundation
import GRDB
import XCTest
@testable import Yggdrasil

/// Fork support: a tracked fork surfaces its upstream (source) repo's issues +
/// PRs, attributed to the fork's own repo_id so worktrees/terminals use the
/// fork's local clone while the GitHub links point at the parent.
final class ForkUpstreamSyncTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func insertRepo(
        _ db: YggdrasilDatabase, owner: String, name: String,
        upstreamOwner: String? = nil, upstreamName: String? = nil,
        upstreamCheckedAt: Date?
    ) throws -> Int64 {
        try db.queue.write { dbW in
            var repo = Repo(
                id: nil, owner: owner, name: name, defaultBranch: "main",
                localMainPath: nil, addedAt: epoch,
                upstreamOwner: upstreamOwner, upstreamName: upstreamName,
                upstreamCheckedAt: upstreamCheckedAt
            )
            try repo.insert(dbW)
            return repo.id!
        }
    }

    private func issueBody(owner: String, name: String, number: Int, title: String) -> String {
        """
        {
          "url": "https://api.github.com/repos/\(owner)/\(name)/issues/\(number)",
          "repository_url": "https://api.github.com/repos/\(owner)/\(name)",
          "html_url": "https://github.com/\(owner)/\(name)/issues/\(number)",
          "number": \(number), "title": "\(title)", "user": { "login": "author" },
          "state": "open", "body": null,
          "created_at": "2026-05-20T10:00:00Z", "updated_at": "2026-05-20T10:00:00Z",
          "assignees": [], "pull_request": null
        }
        """
    }

    private func result(_ json: String) -> HTTPResult {
        HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
    }

    private func sync(_ db: YggdrasilDatabase, _ http: CannedHTTPClient) -> TaskSyncService {
        TaskSyncService(database: db, rest: RESTClient(http: http), graphql: GraphQLClient(http: http))
    }

    func testUpstreamIssueAttributedToFork() async throws {
        // The reported bug: a tracked fork whose issues live upstream. The
        // upstream-owned issue must be attributed to the fork's repo_id (so the
        // worktree/terminal use the fork's clone) and survive the stale prune.
        let db = try YggdrasilDatabase.inMemory()
        let forkID = try insertRepo(
            db, owner: "freemans13", name: "teranode",
            upstreamOwner: "bsv-blockchain", upstreamName: "teranode",
            upstreamCheckedAt: epoch
        )
        let http = CannedHTTPClient(responses: [result(
            "[\(issueBody(owner: "bsv-blockchain", name: "teranode", number: 7, title: "Upstream issue"))]"
        )])
        try await sync(db, http).fullSync()

        let tasks = try await db.queue.read { db in try YggdrasilTask.fetchAll(db) }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].repoID, forkID, "upstream issue attributed to the fork's repo_id")
        XCTAssertEqual(tasks[0].number, 7)
        // The task keeps the upstream html_url, so the GitHub pane opens the
        // parent's issue even though the task lives under the fork.
        XCTAssertEqual(tasks[0].githubURL, "https://github.com/bsv-blockchain/teranode/issues/7")
    }

    func testBackfillResolvesUpstreamThenAttributes() async throws {
        // A fork added before the upstream columns existed: upstreamCheckedAt is
        // nil, so fullSync probes repoInfo, records the source, and this same
        // cycle attributes the upstream issue to the fork.
        let db = try YggdrasilDatabase.inMemory()
        let forkID = try insertRepo(
            db, owner: "freemans13", name: "teranode", upstreamCheckedAt: nil
        )
        // Order: backfill's GET /repos first, then GET /issues (assigned).
        let http = CannedHTTPClient(responses: [
            result("""
            { "default_branch": "main", "fork": true,
              "source": { "full_name": "bsv-blockchain/teranode" } }
            """),
            result("[\(issueBody(owner: "bsv-blockchain", name: "teranode", number: 9, title: "Upstream"))]")
        ])
        try await sync(db, http).fullSync()

        let repo = try await db.queue.read { db in try Repo.fetchOne(db, key: forkID) }
        XCTAssertEqual(repo?.upstreamOwner, "bsv-blockchain")
        XCTAssertEqual(repo?.upstreamName, "teranode")
        XCTAssertNotNil(repo?.upstreamCheckedAt, "probe marks the repo resolved")

        let tasks = try await db.queue.read { db in try YggdrasilTask.fetchAll(db) }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].repoID, forkID)
        XCTAssertEqual(tasks[0].number, 9)
    }

    func testNonForkResolvedOnceWithoutReprobing() async throws {
        // A non-fork with upstreamCheckedAt nil gets probed once; the columns
        // stay nil but checked_at is set, so a second sync doesn't re-probe.
        let db = try YggdrasilDatabase.inMemory()
        let repoID = try insertRepo(db, owner: "o", name: "r", upstreamCheckedAt: nil)
        let issues = "[\(issueBody(owner: "o", name: "r", number: 1, title: "T"))]"
        let http = CannedHTTPClient(responses: [
            result("{\"default_branch\":\"main\",\"fork\":false}"),
            result(issues),
            result(issues) // second sync must NOT consume a repoInfo probe
        ])

        try await sync(db, http).fullSync()
        try await sync(db, http).fullSync()

        let repoProbes = http.calledURLs.filter { $0.path == "/repos/o/r" }.count
        XCTAssertEqual(repoProbes, 1, "non-fork probed once, not re-probed on later syncs")
        let repo = try await db.queue.read { db in try Repo.fetchOne(db, key: repoID) }
        XCTAssertNil(repo?.upstreamOwner)
        XCTAssertNotNil(repo?.upstreamCheckedAt)
    }
}
