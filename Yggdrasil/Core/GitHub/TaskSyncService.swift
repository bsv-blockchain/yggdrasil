import Foundation
import GRDB

/// Orchestrates the periodic GitHub → SQLite sync.
///
/// Each `fullSync()` is a single conceptual unit:
/// 1. Read tracked repos from `repo` table. Bail early if there are none.
/// 2. Pull all assigned issues + PRs in one REST call.
/// 3. Filter to repos that are actually tracked.
/// 4. For each PR, call the GraphQL detail.
/// 5. Apply the result inside one DB transaction: upsert tasks + assignees +
///    github_status, then delete any task rows from tracked repos that are no
///    longer in the response (closed / unassigned / merged).
actor TaskSyncService {
    private let database: YggdrasilDatabase
    private let rest: RESTClient
    private let graphql: GraphQLClient

    init(database: YggdrasilDatabase, rest: RESTClient, graphql: GraphQLClient) {
        self.database = database
        self.rest = rest
        self.graphql = graphql
    }

    func fullSync() async throws {
        let trackedRepos = try await database.queue.read { db in try Repo.fetchAll(db) }
        guard !trackedRepos.isEmpty else {
            YggdrasilLog.sync.info("No tracked repos; sync is a no-op")
            return
        }
        let trackedKey: [String: Repo] = Dictionary(
            uniqueKeysWithValues: trackedRepos.map { ("\($0.owner)/\($0.name)", $0) }
        )

        YggdrasilLog.sync.info("Starting full sync over \(trackedRepos.count, privacy: .public) tracked repos")
        let assigned = try await rest.assignedIssues()
        let relevant = assigned.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }
        YggdrasilLog.sync.info(
            "REST returned \(assigned.count, privacy: .public) assigned tasks, \(relevant.count, privacy: .public) within tracked repos"
        )

        var prDetails: [String: PRDetail] = [:]
        for raw in relevant where raw.type == .pullRequest {
            let detail = try await graphql.prDetail(
                owner: raw.repoOwner, repo: raw.repoName, number: raw.number
            )
            prDetails[Self.compositeKey(owner: raw.repoOwner, name: raw.repoName, number: raw.number)] = detail
        }

        let now = Date()
        try await database.queue.write { db in
            try TaskSyncWrites.applyUpserts(
                db: db, raws: relevant, repos: trackedKey, prDetails: prDetails, now: now
            )
            try TaskSyncWrites.deleteStaleTasks(db: db, repos: trackedRepos, fetched: relevant)
        }
        YggdrasilLog.sync.info("Full sync complete")
    }

    static func compositeKey(owner: String, name: String, number: Int) -> String {
        "\(owner)/\(name)#\(number)"
    }
}

/// All the DB-touching code lives in this `nonisolated` namespace so the writes
/// can run inside a GRDB transaction closure (which is itself synchronous and
/// non-isolated).
enum TaskSyncWrites {
    static func applyUpserts(
        db: Database,
        raws: [RawTask],
        repos: [String: Repo],
        prDetails: [String: PRDetail],
        now: Date
    ) throws {
        for raw in raws {
            guard let repoRow = repos["\(raw.repoOwner)/\(raw.repoName)"], let repoID = repoRow.id else {
                continue
            }
            try upsertTask(db: db, raw: raw, repoID: repoID, now: now, prDetails: prDetails)
        }
    }

    private static func upsertTask(
        db: Database,
        raw: RawTask,
        repoID: Int64,
        now: Date,
        prDetails: [String: PRDetail]
    ) throws {
        let existingID: Int64? = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
            arguments: [repoID, raw.type.rawValue, raw.number]
        )
        var task = YggdrasilTask(
            id: existingID,
            repoID: repoID,
            type: raw.type,
            number: raw.number,
            title: raw.title,
            body: raw.body,
            state: raw.state,
            authorLogin: raw.authorLogin,
            githubURL: raw.githubURL,
            apiURL: raw.apiURL,
            createdAt: raw.createdAt,
            updatedAt: raw.updatedAt,
            lastSyncedAt: now,
            etag: nil
        )
        try task.save(db)
        let taskID = task.id!

        try db.execute(sql: "DELETE FROM task_assignee WHERE task_id = ?", arguments: [taskID])
        for login in raw.assignees {
            try TaskAssignee(taskID: taskID, login: login).insert(db)
        }

        if raw.type == .pullRequest,
           let detail = prDetails[TaskSyncService.compositeKey(
               owner: raw.repoOwner, name: raw.repoName, number: raw.number
           )] {
            let status = GitHubStatus(
                taskID: taskID,
                ciState: detail.ciState,
                ciURL: nil,
                mergeable: detail.mergeable,
                mergeableState: detail.mergeableState,
                reviewState: detail.reviewState,
                unreadCommentsCount: 0,
                lastSeenCommentID: nil,
                fetchedAt: now
            )
            try status.save(db)
        }
    }

    static func deleteStaleTasks(db: Database, repos: [Repo], fetched: [RawTask]) throws {
        var keptByRepoID: [Int64: Set<String>] = [:]
        for raw in fetched {
            guard let repoRow = repos.first(where: {
                $0.owner == raw.repoOwner && $0.name == raw.repoName
            }), let repoID = repoRow.id else { continue }
            keptByRepoID[repoID, default: []].insert("\(raw.type.rawValue)#\(raw.number)")
        }
        for repo in repos {
            guard let repoID = repo.id else { continue }
            let kept = keptByRepoID[repoID] ?? []
            let allForRepo = try YggdrasilTask.fetchAll(
                db, sql: "SELECT * FROM task WHERE repo_id = ?", arguments: [repoID]
            )
            for existing in allForRepo where !kept.contains("\(existing.type.rawValue)#\(existing.number)") {
                try existing.delete(db)
            }
        }
    }
}
