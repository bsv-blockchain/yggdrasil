import Foundation
import GRDB
import XCTest
@testable import Yggdrasil

/// Helper: insert a tracked Repo row and return its id. Defaults to already
/// upstream-resolved (`upstreamCheckedAt` set) so `fullSync` skips the backfill
/// probe — tests that exercise the backfill pass `upstreamCheckedAt: nil`.
private func insertRepo(
    _ db: YggdrasilDatabase,
    owner: String,
    name: String,
    upstreamOwner: String? = nil,
    upstreamName: String? = nil,
    upstreamCheckedAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)
) throws -> Int64 {
    try db.queue.write { dbW in
        var repo = Repo(
            id: nil,
            owner: owner,
            name: name,
            defaultBranch: "main",
            localMainPath: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            upstreamOwner: upstreamOwner,
            upstreamName: upstreamName,
            upstreamCheckedAt: upstreamCheckedAt
        )
        try repo.insert(dbW)
        return repo.id!
    }
}

/// Convenience JSON body for a single issue. Skips PR side-channel.
private func issueJSON(repoOwner: String, repoName: String, number: Int, title: String,
                       state: String = "open", assignees: [String] = []) -> String {
    let assigneesArr = assignees.map { "{\"login\":\"\($0)\"}" }.joined(separator: ",")
    return """
    {
      "url": "https://api.github.com/repos/\(repoOwner)/\(repoName)/issues/\(number)",
      "repository_url": "https://api.github.com/repos/\(repoOwner)/\(repoName)",
      "html_url": "https://github.com/\(repoOwner)/\(repoName)/issues/\(number)",
      "number": \(number),
      "title": "\(title)",
      "user": { "login": "author" },
      "state": "\(state)",
      "body": null,
      "created_at": "2026-05-20T10:00:00Z",
      "updated_at": "2026-05-20T10:00:00Z",
      "assignees": [\(assigneesArr)],
      "pull_request": null
    }
    """
}

/// Convenience JSON body for an issue that is actually a PR (has `pull_request` set).
private func prAsIssueJSON(repoOwner: String, repoName: String, number: Int, title: String,
                           state: String = "open", assignees: [String] = []) -> String {
    let assigneesArr = assignees.map { "{\"login\":\"\($0)\"}" }.joined(separator: ",")
    return """
    {
      "url": "https://api.github.com/repos/\(repoOwner)/\(repoName)/issues/\(number)",
      "repository_url": "https://api.github.com/repos/\(repoOwner)/\(repoName)",
      "html_url": "https://github.com/\(repoOwner)/\(repoName)/pull/\(number)",
      "number": \(number),
      "title": "\(title)",
      "user": { "login": "author" },
      "state": "\(state)",
      "body": null,
      "created_at": "2026-05-20T10:00:00Z",
      "updated_at": "2026-05-20T10:00:00Z",
      "assignees": [\(assigneesArr)],
      "pull_request": {
        "url": "https://api.github.com/repos/\(repoOwner)/\(repoName)/pulls/\(number)",
        "html_url": "https://github.com/\(repoOwner)/\(repoName)/pull/\(number)"
      }
    }
    """
}

private func issuesArray(_ items: [String]) -> Data {
    let body = "[\n" + items.joined(separator: ",\n") + "\n]"
    return Data(body.utf8)
}

private func graphqlPRDetail(_ ciState: String? = "SUCCESS") -> Data {
    let ciJSON = ciState.map { "{\"state\":\"\($0)\"}" } ?? "null"
    let body = """
    {
      "data": {
        "repository": {
          "pullRequest": {
            "mergeable": "MERGEABLE",
            "mergeStateStatus": "CLEAN",
            "reviewDecision": "APPROVED",
            "commits": { "nodes": [{ "commit": { "statusCheckRollup": \(ciJSON) } }] },
            "comments": { "totalCount": 0 },
            "reviews": { "totalCount": 0 }
          }
        }
      }
    }
    """
    return Data(body.utf8)
}

private func httpResult(_ json: String) -> HTTPResult {
    HTTPResult(status: 200, body: Data(json.utf8), etag: nil, rateLimitRemaining: 4999)
}

private func httpResult(_ data: Data) -> HTTPResult {
    HTTPResult(status: 200, body: data, etag: nil, rateLimitRemaining: 4999)
}

final class TaskSyncServiceTests: XCTestCase {
    func testFullSyncInsertsTasksForTrackedReposOnly() async throws {
        let db = try YggdrasilDatabase.inMemory()
        let repoID = try insertRepo(db, owner: "bsv-blockchain", name: "teranode")
        // Note: bsv-blockchain/untracked is NOT inserted as a tracked repo.

        let issueResp = issuesArray([
            issueJSON(repoOwner: "bsv-blockchain", repoName: "teranode", number: 1, title: "Tracked"),
            issueJSON(repoOwner: "bsv-blockchain", repoName: "untracked", number: 2, title: "Other")
        ])
        let http = CannedHTTPClient(responses: [httpResult(issueResp)])
        let sync = TaskSyncService(
            database: db,
            rest: RESTClient(http: http),
            graphql: GraphQLClient(http: http)
        )

        try await sync.fullSync()

        let tasks = try await db.queue.read { db in try YggdrasilTask.fetchAll(db) }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].repoID, repoID)
        XCTAssertEqual(tasks[0].number, 1)
        XCTAssertEqual(tasks[0].title, "Tracked")
    }

    func testFullSyncIsIdempotent() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")

        let json = issuesArray([
            issueJSON(repoOwner: "o", repoName: "r", number: 1, title: "T1", assignees: ["sigi"])
        ])
        let http = CannedHTTPClient(responses: [httpResult(json), httpResult(json)])
        let sync = TaskSyncService(
            database: db,
            rest: RESTClient(http: http),
            graphql: GraphQLClient(http: http)
        )

        try await sync.fullSync()
        try await sync.fullSync()

        let tasks = try await db.queue.read { db in try YggdrasilTask.fetchAll(db) }
        let assignees = try await db.queue.read { db in try TaskAssignee.fetchAll(db) }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(assignees.count, 1)
        XCTAssertEqual(assignees[0].login, "sigi")
    }

    func testServerWinsForTaskTitle() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")
        let json = issuesArray([
            issueJSON(repoOwner: "o", repoName: "r", number: 1, title: "v1")
        ])
        let http = CannedHTTPClient(responses: [httpResult(json)])
        let sync = TaskSyncService(
            database: db,
            rest: RESTClient(http: http),
            graphql: GraphQLClient(http: http)
        )
        try await sync.fullSync()

        // Now sync returns a *new* title for the same (repo, type, number).
        let json2 = issuesArray([
            issueJSON(repoOwner: "o", repoName: "r", number: 1, title: "v2")
        ])
        let http2 = CannedHTTPClient(responses: [httpResult(json2)])
        let sync2 = TaskSyncService(
            database: db,
            rest: RESTClient(http: http2),
            graphql: GraphQLClient(http: http2)
        )
        try await sync2.fullSync()

        let tasks = try await db.queue.read { db in try YggdrasilTask.fetchAll(db) }
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].title, "v2")
    }

    func testRemovesTasksNoLongerInResponse() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")

        let firstJSON = issuesArray([
            issueJSON(repoOwner: "o", repoName: "r", number: 1, title: "Stays"),
            issueJSON(repoOwner: "o", repoName: "r", number: 2, title: "Will go away")
        ])
        let http1 = CannedHTTPClient(responses: [httpResult(firstJSON)])
        try await TaskSyncService(
            database: db, rest: RESTClient(http: http1), graphql: GraphQLClient(http: http1)
        ).fullSync()
        let countAfterFirst = try await db.queue.read { try YggdrasilTask.fetchCount($0) }
        XCTAssertEqual(countAfterFirst, 2)

        let secondJSON = issuesArray([
            issueJSON(repoOwner: "o", repoName: "r", number: 1, title: "Stays")
        ])
        let http2 = CannedHTTPClient(responses: [httpResult(secondJSON)])
        try await TaskSyncService(
            database: db, rest: RESTClient(http: http2), graphql: GraphQLClient(http: http2)
        ).fullSync()

        let nums = try await db.queue.read { db in
            try Int.fetchAll(db, sql: "SELECT number FROM task ORDER BY number")
        }
        XCTAssertEqual(nums, [1])
    }

    func testEmptyResultsAreNotAnError() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")
        let http = CannedHTTPClient(responses: [httpResult("[]")])
        try await TaskSyncService(
            database: db, rest: RESTClient(http: http), graphql: GraphQLClient(http: http)
        ).fullSync()
        let emptyCount = try await db.queue.read { try YggdrasilTask.fetchCount($0) }
        XCTAssertEqual(emptyCount, 0)
    }

    func testNoTrackedReposIsNoOp() async throws {
        let db = try YggdrasilDatabase.inMemory()
        let http = CannedHTTPClient(responses: [])
        try await TaskSyncService(
            database: db, rest: RESTClient(http: http), graphql: GraphQLClient(http: http)
        ).fullSync()
        // Should not have called the REST client at all.
        XCTAssertTrue(http.calledURLs.isEmpty)
    }

    func testPRTasksGetGitHubStatusFromGraphQL() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")
        // REST returns one PR-shaped issue; sync should follow up with one GraphQL detail.
        let issuesJSON = issuesArray([
            prAsIssueJSON(repoOwner: "o", repoName: "r", number: 100, title: "PR title")
        ])
        let http = CannedHTTPClient(responses: [
            httpResult(issuesJSON),
            httpResult(graphqlPRDetail("FAILURE"))
        ])
        try await TaskSyncService(
            database: db, rest: RESTClient(http: http), graphql: GraphQLClient(http: http)
        ).fullSync()

        let statuses = try await db.queue.read { db in try GitHubStatus.fetchAll(db) }
        XCTAssertEqual(statuses.count, 1)
        XCTAssertEqual(statuses[0].ciState, "FAILURE")
        XCTAssertEqual(statuses[0].mergeable, true)
        XCTAssertEqual(statuses[0].reviewState, "APPROVED")
    }

    func test_importPR_insertsTaskAndReturnsID() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")

        let prJSON = """
        {
          "url": "https://api.github.com/repos/o/r/pulls/828",
          "html_url": "https://github.com/o/r/pull/828",
          "number": 828, "title": "Bulk utxos",
          "user": { "login": "siggi" }, "state": "open", "body": null,
          "created_at": "2026-05-29T10:00:00Z",
          "updated_at": "2026-05-29T11:00:00Z",
          "assignees": [], "draft": false, "merged_at": null,
          "head": { "ref": "feat/bulk-utxos" }
        }
        """
        let detailJSON = """
        {"data":{"repository":{"pullRequest":{"mergeable":"UNKNOWN","reviewDecision":null,"commits":{"nodes":[]}}}}}
        """
        let http = CannedHTTPClient(responses: [
            httpResult(prJSON),
            httpResult(detailJSON)
        ])
        let sync = TaskSyncService(
            database: db,
            rest: RESTClient(http: http),
            graphql: GraphQLClient(http: http)
        )

        let taskID = try await sync.importPR(owner: "o", name: "r", number: 828)

        let (count, savedNumber): (Int, Int?) = try await db.queue.read { dbR in
            let rowCount = try Int
                .fetchOne(dbR, sql: "SELECT COUNT(*) FROM task WHERE id = ?", arguments: [taskID]) ?? 0
            let number = try Int.fetchOne(dbR, sql: "SELECT number FROM task WHERE id = ?", arguments: [taskID])
            return (rowCount, number)
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(savedNumber, 828)

        let statusCount: Int = try await db.queue.read { dbR in
            try Int.fetchOne(dbR, sql: "SELECT COUNT(*) FROM github_status WHERE task_id = ?", arguments: [taskID]) ?? 0
        }
        XCTAssertEqual(statusCount, 1, "importPR should write a github_status row from the GraphQL detail")
    }

    func test_linkablePRNumber_matchesHeadBranch() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")
        let listJSON = """
        [
          {"url":"u","html_url":"h","number":12,"title":"t","user":{"login":"a"},
           "state":"open","body":null,"created_at":"2026-05-29T10:00:00Z",
           "updated_at":"2026-05-29T11:00:00Z","assignees":[],"draft":false,
           "merged_at":null,"head":{"ref":"other-branch"}},
          {"url":"u","html_url":"h","number":828,"title":"t","user":{"login":"a"},
           "state":"open","body":null,"created_at":"2026-05-29T10:00:00Z",
           "updated_at":"2026-05-29T11:00:00Z","assignees":[],"draft":false,
           "merged_at":null,"head":{"ref":"feat/bulk-utxos"}}
        ]
        """
        let http = CannedHTTPClient(responses: [httpResult(listJSON)])
        let sync = TaskSyncService(
            database: db,
            rest: RESTClient(http: http),
            graphql: GraphQLClient(http: http)
        )
        let match = try await sync.linkablePRNumber(forBranch: "feat/bulk-utxos", owner: "o", name: "r")
        XCTAssertEqual(match, 828)

        let http2 = CannedHTTPClient(responses: [httpResult(listJSON)])
        let sync2 = TaskSyncService(
            database: db,
            rest: RESTClient(http: http2),
            graphql: GraphQLClient(http: http2)
        )
        let none = try await sync2.linkablePRNumber(forBranch: "no-such-branch", owner: "o", name: "r")
        XCTAssertNil(none)
    }

    func testNetworkErrorLeavesPreviousStateIntact() async throws {
        let db = try YggdrasilDatabase.inMemory()
        _ = try insertRepo(db, owner: "o", name: "r")

        let firstJSON = issuesArray([
            issueJSON(repoOwner: "o", repoName: "r", number: 1, title: "First")
        ])
        try await TaskSyncService(
            database: db,
            rest: RESTClient(http: CannedHTTPClient(responses: [httpResult(firstJSON)])),
            graphql: GraphQLClient(http: CannedHTTPClient(responses: []))
        ).fullSync()
        let countBefore = try await db.queue.read { try YggdrasilTask.fetchCount($0) }
        XCTAssertEqual(countBefore, 1)

        // Now the network is dead — sync throws, DB unchanged.
        let badHTTP = CannedHTTPClient(responses: []) // no canned responses → .requestFailed
        do {
            try await TaskSyncService(
                database: db, rest: RESTClient(http: badHTTP), graphql: GraphQLClient(http: badHTTP)
            ).fullSync()
            XCTFail("expected throw")
        } catch {
            // expected
        }
        let countAfter = try await db.queue.read { try YggdrasilTask.fetchCount($0) }
        XCTAssertEqual(countAfter, 1)
    }

    func test_deleteStaleTasks_keepsTabLinkedTasks() throws {
        let db = try YggdrasilDatabase.inMemory()
        let repoID = try insertRepo(db, owner: "o", name: "r")
        let epoch = Date(timeIntervalSince1970: 0)

        let survivingNumbers: [Int] = try db.queue.write { dbW -> [Int] in
            func makeTask(_ number: Int) throws -> Int64 {
                var task = YggdrasilTask(
                    id: nil, repoID: repoID, type: .pullRequest, number: number,
                    title: "t\(number)", body: nil, state: .open, authorLogin: "x",
                    githubURL: "", apiURL: "",
                    createdAt: epoch, updatedAt: epoch, lastSyncedAt: epoch,
                    etag: nil, labelsJSON: "[]", milestoneTitle: nil
                )
                try task.insert(dbW)
                return task.id!
            }
            let linkedID = try makeTask(101)
            _ = try makeTask(102) // unlinked → should be pruned

            var tab = YggdrasilTab(
                id: nil, taskID: linkedID, codingAgentID: nil, position: 0,
                branchName: "feat/x", worktreePath: "/tmp/x", lastMainView: .agent,
                createdAt: epoch, lastActiveAt: epoch
            )
            try tab.insert(dbW)

            let repo = try Repo.fetchOne(dbW, key: repoID)!
            // Empty fetched-set: BOTH tasks are stale by the synced-list rule.
            // Only the tab-linked one (101) must survive.
            try TaskSyncWrites.deleteStaleTasks(db: dbW, repos: [repo], fetched: [])

            return try Int.fetchAll(dbW, sql: "SELECT number FROM task ORDER BY number")
        }

        XCTAssertEqual(survivingNumbers, [101],
                       "tab-linked task survives prune; unlinked stale task is deleted")
    }
}
