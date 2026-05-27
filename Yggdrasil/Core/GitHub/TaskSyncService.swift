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
        let relevantAssigned = assigned.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }

        // Three orthogonal axes feed the task table. Each list is filtered to
        // tracked repos, merged via composite key for the upsert, and then
        // used independently to rebuild its dedicated membership table.
        let reviewRequested = (try? await rest.reviewRequestedPRs()) ?? []
        let relevantReview = reviewRequested.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }

        let authored = (try? await rest.authoredPRs()) ?? []
        let relevantAuthored = authored.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }

        // Union for the upsert / stale-prune pass; same-keyed raws collapse.
        var merged: [RawTask] = relevantAssigned
        var seen = Set(relevantAssigned.map { Self.compositeKey(owner: $0.repoOwner, name: $0.repoName, number: $0.number) })
        for raw in relevantReview + relevantAuthored {
            let key = Self.compositeKey(owner: raw.repoOwner, name: raw.repoName, number: raw.number)
            if seen.insert(key).inserted {
                merged.append(raw)
            }
        }
        YggdrasilLog.sync.info(
            "REST: \(assigned.count, privacy: .public) assigned (\(relevantAssigned.count, privacy: .public) tracked); \(reviewRequested.count, privacy: .public) review-requested (\(relevantReview.count, privacy: .public) tracked); \(authored.count, privacy: .public) authored (\(relevantAuthored.count, privacy: .public) tracked)"
        )

        var prDetails: [String: PRDetail] = [:]
        for raw in merged where raw.type == .pullRequest {
            let detail = try await graphql.prDetail(
                owner: raw.repoOwner, repo: raw.repoName, number: raw.number
            )
            prDetails[Self.compositeKey(owner: raw.repoOwner, name: raw.repoName, number: raw.number)] = detail
        }

        let now = Date()
        try await database.queue.write { db in
            try TaskSyncWrites.applyUpserts(
                db: db, raws: merged, repos: trackedKey, prDetails: prDetails, now: now
            )
            try TaskSyncWrites.deleteStaleTasks(db: db, repos: trackedRepos, fetched: merged)
            try TaskSyncWrites.applyReviewRequests(
                db: db, raws: relevantReview, repos: trackedKey, now: now
            )
            try TaskSyncWrites.applyAuthoredPRs(
                db: db, raws: relevantAuthored, repos: trackedKey, now: now
            )
            try TaskSyncWrites.applyAssignedPRs(
                db: db, raws: relevantAssigned, repos: trackedKey, now: now
            )
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
        // Re-encode labels as JSON for the labels_json column. Stable order
        // (RawTask doesn't sort) so identical fetches don't churn the row.
        let labelsJSON: String = {
            let data = (try? JSONEncoder().encode(raw.labels.map { label in
                YggdrasilTask.Label(name: label.name, color: label.color)
            })) ?? Data("[]".utf8)
            return String(data: data, encoding: .utf8) ?? "[]"
        }()
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
            etag: nil,
            labelsJSON: labelsJSON,
            milestoneTitle: raw.milestoneTitle
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

    /// Replaces the `pr_review_request` table contents for tracked repos
    /// with the set of PRs the user has been asked to review. PRs that drop
    /// out of `raws` (review dismissed, PR closed, …) get their row removed.
    /// Runs inside the same transaction as `applyUpserts` so a partial sync
    /// can't leave the membership table out of step with the task table.
    static func applyReviewRequests(
        db: Database,
        raws: [RawTask],
        repos: [String: Repo],
        now: Date
    ) throws {
        // Wipe and rewrite. The table is tiny (one row per outstanding
        // review request) and the search endpoint returns the full current
        // set, so an authoritative replace is simpler than a diff.
        try db.execute(sql: "DELETE FROM pr_review_request")
        for raw in raws where raw.type == .pullRequest {
            guard let repo = repos["\(raw.repoOwner)/\(raw.repoName)"], let repoID = repo.id else { continue }
            let taskID: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
                arguments: [repoID, raw.type.rawValue, raw.number]
            )
            guard let taskID else { continue }
            try PRReviewRequest(taskID: taskID, requestedAt: now).insert(db)
        }
    }

    /// Rebuild `pr_authored` from the set of PRs returned by
    /// `is:pr author:@me`. Same authoritative-replace pattern as
    /// `applyReviewRequests` — the search endpoint always returns the
    /// complete current set, so it's simpler to wipe + reinsert than diff.
    static func applyAuthoredPRs(
        db: Database,
        raws: [RawTask],
        repos: [String: Repo],
        now: Date
    ) throws {
        try db.execute(sql: "DELETE FROM pr_authored")
        for raw in raws where raw.type == .pullRequest {
            guard let repo = repos["\(raw.repoOwner)/\(raw.repoName)"], let repoID = repo.id else { continue }
            let taskID: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
                arguments: [repoID, raw.type.rawValue, raw.number]
            )
            guard let taskID else { continue }
            try PRAuthored(taskID: taskID, recordedAt: now).insert(db)
        }
    }

    /// Rebuild `pr_assigned` from the PR subset of `/issues?filter=assigned`.
    /// Distinguishes "PR I'm an assignee on" from generic task-assignee
    /// membership (which holds arbitrary logins, not just me).
    static func applyAssignedPRs(
        db: Database,
        raws: [RawTask],
        repos: [String: Repo],
        now: Date
    ) throws {
        try db.execute(sql: "DELETE FROM pr_assigned")
        for raw in raws where raw.type == .pullRequest {
            guard let repo = repos["\(raw.repoOwner)/\(raw.repoName)"], let repoID = repo.id else { continue }
            let taskID: Int64? = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
                arguments: [repoID, raw.type.rawValue, raw.number]
            )
            guard let taskID else { continue }
            try PRAssigned(taskID: taskID, recordedAt: now).insert(db)
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
