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
        var trackedRepos = try await database.queue.read { db in try Repo.fetchAll(db) }
        guard !trackedRepos.isEmpty else {
            YggdrasilLog.sync.info("No tracked repos; sync is a no-op")
            return
        }
        // Resolve fork upstreams before building the match table so a fork's
        // upstream-owned issues/PRs resolve to the fork's repo_id this cycle.
        trackedRepos = await backfillUpstreams(trackedRepos)
        let trackedKey: [String: Repo] = Dictionary(
            trackedRepos.flatMap { repo in
                repo.issueSources.map { ("\($0.owner)/\($0.name)", repo) }
            },
            uniquingKeysWith: { existing, _ in existing }
        )

        YggdrasilLog.sync.info("Starting full sync over \(trackedRepos.count, privacy: .public) tracked repos")
        let assigned = try await rest.assignedIssues()
        let relevantAssigned = assigned.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }

        // Three orthogonal axes feed the task table. Each list is filtered to
        // tracked repos, merged via composite key for the upsert, and then
        // used independently to rebuild its dedicated membership table.
        let reviewRequested = await (try? rest.reviewRequestedPRs()) ?? []
        let relevantReview = reviewRequested.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }

        let authored = await (try? rest.authoredPRs()) ?? []
        let relevantAuthored = authored.filter { trackedKey["\($0.repoOwner)/\($0.repoName)"] != nil }

        // Union for the upsert / stale-prune pass; same-keyed raws collapse.
        var merged: [RawTask] = relevantAssigned
        var seen = Set(relevantAssigned.map { Self.compositeKey(
            owner: $0.repoOwner,
            name: $0.repoName,
            number: $0.number
        ) })
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
        await refreshLinkedPRs(alreadyFetched: seen)
        YggdrasilLog.sync.info("Full sync complete")
    }

    /// Refresh the detail (+ `github_status`) of any PR that has a live tab but
    /// wasn't in the assigned/review-requested/authored search results this
    /// cycle. Without this, a review PR freezes as soon as you submit a review:
    /// GitHub drops you from its requested-reviewers list, so it falls out of
    /// every search list and its `github_status` — and thus the REVIEW pill —
    /// is never refreshed again, leaving it stuck on stale pre-review data.
    /// Best-effort per PR: a failed fetch just leaves that PR for next cycle.
    private func refreshLinkedPRs(alreadyFetched: Set<String>) async {
        let linked = await (try? database.queue.read { db in
            try LinkedPRRef.fetchAll(db)
        }) ?? []
        for linkedPR in linked {
            let key = Self.compositeKey(owner: linkedPR.owner, name: linkedPR.name, number: linkedPR.number)
            guard !alreadyFetched.contains(key) else { continue }
            guard let raw = try? await rest.pullRequest(
                owner: linkedPR.owner, name: linkedPR.name, number: linkedPR.number
            ) else { continue }
            let detail = try? await graphql.prDetail(
                owner: linkedPR.owner, repo: linkedPR.name, number: linkedPR.number
            )
            let now = Date()
            try? await database.queue.write { db in
                _ = try TaskSyncWrites.upsertSingleTask(
                    db: db, raw: raw, repoID: linkedPR.repoID, detail: detail, now: now
                )
            }
        }
    }

    /// Fetch one PR by number, upsert it into the task table (+ github_status
    /// from a GraphQL detail), and return its task id. Powers "Link PR" — a
    /// PR the user just opened may not be in any synced list yet, so we fetch
    /// it on demand rather than waiting for the next fullSync.
    ///
    /// A linked PR survives sync even when it isn't in any synced list
    /// (e.g. one the user didn't author and isn't assigned/review-requested
    /// on): `deleteStaleTasks` skips any task referenced by a live
    /// `tab.task_id`. The link persists for as long as the tab exists; once
    /// the tab is removed the task becomes prunable again on the next sync.
    func importPR(owner: String, name: String, number: Int) async throws -> Int64 {
        let repoID = try await database.queue.read { db -> Int64 in
            guard let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM repo WHERE owner = ? AND name = ?",
                arguments: [owner, name]
            ) else {
                throw GitHubError.decodingFailed("importPR: repo \(owner)/\(name) not tracked")
            }
            return id
        }
        let raw = try await rest.pullRequest(owner: owner, name: name, number: number)
        let detail = try? await graphql.prDetail(owner: owner, repo: name, number: number)
        let now = Date()
        return try await database.queue.write { db in
            try TaskSyncWrites.upsertSingleTask(
                db: db, raw: raw, repoID: repoID, detail: detail, now: now
            )
        }
    }

    /// Among the repo's open PRs, the number whose head branch equals
    /// `branch`, else nil. Used to pre-fill the Link PR dialog from the
    /// tab's worktree branch.
    func linkablePRNumber(forBranch branch: String, owner: String, name: String) async throws -> Int? {
        let openPRs = try await rest.openPRs(forOwner: owner, name: name)
        return openPRs.first(where: { $0.headRef == branch })?.number
    }

    static func compositeKey(owner: String, name: String, number: Int) -> String {
        "\(owner)/\(name)#\(number)"
    }

    /// Resolve the fork upstream for any tracked repo not yet probed (one
    /// `GET /repos/{owner}/{repo}` each, ever). Populates `upstream_owner`/`name`
    /// so upstream-owned issues + PRs get attributed to the fork's `repo_id`.
    /// `upstream_checked_at` marks a repo resolved — including non-forks, whose
    /// upstream columns stay NULL — so we don't re-probe every sync. Best-effort:
    /// a failed probe leaves the repo unresolved and is retried next sync.
    private func backfillUpstreams(_ repos: [Repo]) async -> [Repo] {
        var result = repos
        for index in repos.indices where repos[index].upstreamCheckedAt == nil {
            let repo = repos[index]
            guard let id = repo.id,
                  let info = try? await rest.repoInfo(owner: repo.owner, name: repo.name)
            else { continue }
            let upstreamOwner = info.isFork ? info.upstreamOwner : nil
            let upstreamName = info.isFork ? info.upstreamName : nil
            let now = Date()
            do {
                try await database.queue.write { db in
                    try db.execute(
                        sql: """
                        UPDATE repo
                        SET upstream_owner = ?, upstream_name = ?, upstream_checked_at = ?
                        WHERE id = ?
                        """,
                        arguments: [upstreamOwner, upstreamName, now, id]
                    )
                }
                result[index].upstreamOwner = upstreamOwner
                result[index].upstreamName = upstreamName
                result[index].upstreamCheckedAt = now
                if let upstreamOwner, let upstreamName {
                    YggdrasilLog.sync.info(
                        "Resolved fork upstream \(repo.fullName, privacy: .public) -> \(upstreamOwner, privacy: .public)/\(upstreamName, privacy: .public)"
                    )
                }
            } catch {
                YggdrasilLog.sync.error(
                    "Upstream backfill failed for \(repo.fullName, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
        return result
    }
}

/// A PR task that has a live tab, resolved to the owner/name/number needed to
/// re-fetch it. Owner/name come from the task's GitHub URL — i.e. where the PR
/// actually lives (the upstream, for a fork), which is what the fetch needs.
private struct LinkedPRRef {
    let repoID: Int64
    let owner: String
    let name: String
    let number: Int

    static func fetchAll(_ db: Database) throws -> [LinkedPRRef] {
        let rows = try Row.fetchAll(db, sql: """
        SELECT repo_id, github_url, number FROM task
        WHERE type = ?
          AND id IN (
            SELECT task_id FROM tab WHERE task_id IS NOT NULL
            UNION
            SELECT pr_task_id FROM tab WHERE pr_task_id IS NOT NULL
          )
        """, arguments: [YggdrasilTask.Kind.pullRequest.rawValue])
        return rows.compactMap { row in
            guard let repoID = row["repo_id"] as Int64?,
                  let number = row["number"] as Int?,
                  let parsed = parseOwnerName(row["github_url"]) else { return nil }
            return LinkedPRRef(repoID: repoID, owner: parsed.owner, name: parsed.name, number: number)
        }
    }

    /// `https://github.com/<owner>/<name>/pull/<n>` → (owner, name).
    private static func parseOwnerName(_ url: String?) -> (owner: String, name: String)? {
        guard let url, let comps = URL(string: url)?.pathComponents, comps.count >= 3 else { return nil }
        // pathComponents = ["/", owner, name, "pull", "<n>"]
        return (comps[1], comps[2])
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

    /// Upsert a single task row (+ github_status when a PRDetail is given)
    /// and return its id. Reuses the same `upsertTask` write path as the
    /// full sync so a linked PR is indistinguishable from a synced one.
    static func upsertSingleTask(
        db: Database,
        raw: RawTask,
        repoID: Int64,
        detail: PRDetail?,
        now: Date
    ) throws -> Int64 {
        var prDetails: [String: PRDetail] = [:]
        if let detail {
            prDetails[TaskSyncService.compositeKey(
                owner: raw.repoOwner, name: raw.repoName, number: raw.number
            )] = detail
        }
        try upsertTask(db: db, raw: raw, repoID: repoID, now: now, prDetails: prDetails)
        guard let id = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
            arguments: [repoID, raw.type.rawValue, raw.number]
        ) else {
            throw GitHubError.decodingFailed("upsertSingleTask: task row not found after upsert")
        }
        return id
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
            try upsertGitHubStatus(db: db, taskID: taskID, detail: detail, now: now)
        }
    }

    /// Write the PR's `github_status` row from a GraphQL detail. Refreshes the
    /// current activity counts + per-viewer review state each sync, while
    /// preserving the user's "seen" baseline (seeded to current on first sight
    /// so an already-active PR isn't flagged as unseen activity).
    private static func upsertGitHubStatus(
        db: Database, taskID: Int64, detail: PRDetail, now: Date
    ) throws {
        // Include inline review-thread comments so an author replying to review
        // feedback registers as activity, not just issue comments.
        let commentsReviews = detail.commentsTotal + detail.reviewsTotal + detail.reviewCommentsTotal
        let existing = try GitHubStatus.fetchOne(db, key: taskID)
        let status = GitHubStatus(
            taskID: taskID,
            ciState: detail.ciState,
            ciURL: nil,
            mergeable: detail.mergeable,
            mergeableState: detail.mergeableState,
            reviewState: detail.reviewState,
            unreadCommentsCount: 0,
            lastSeenCommentID: nil,
            fetchedAt: now,
            commentsReviewsTotal: commentsReviews,
            commitsTotal: detail.commitsTotal,
            headSHA: detail.headSHA,
            seenCommentsReviewsTotal: existing?.seenCommentsReviewsTotal ?? commentsReviews,
            seenCommitsTotal: existing?.seenCommitsTotal ?? detail.commitsTotal,
            seenHeadSHA: existing?.seenHeadSHA ?? detail.headSHA,
            viewerLatestReviewState: detail.viewerLatestReviewState,
            viewerReviewedHeadSHA: detail.viewerReviewedHeadSHA,
            unresolvedThreadsAwaitingViewer: detail.unresolvedThreadsAwaitingViewer,
            viewerLastEngagementAt: detail.viewerLastEngagementAt,
            headCommittedAt: detail.headCommittedAt,
            viewerReviewRequested: detail.viewerReviewRequested
        )
        try status.save(db)
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
        // Task ids referenced by a live tab are never pruned, even when they
        // drop out of (or never appeared in) the synced lists. This is what
        // lets a manually-linked PR — including one the user didn't author
        // and isn't assigned/review-requested on — survive the sync that
        // `importPR` triggers. See `importPR`.
        let linkedTaskIDs = try Int64.fetchSet(
            db, sql: "SELECT task_id FROM tab WHERE task_id IS NOT NULL"
        )
        var keptByRepoID: [Int64: Set<String>] = [:]
        for raw in fetched {
            // Match on issueSources (own + fork upstream) so an upstream-owned
            // raw resolves to the fork's repo_id — otherwise it'd be pruned in
            // the same transaction that just inserted it.
            guard let repoRow = repos.first(where: { repo in
                repo.issueSources.contains { $0.owner == raw.repoOwner && $0.name == raw.repoName }
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
                if let id = existing.id, linkedTaskIDs.contains(id) { continue }
                try existing.delete(db)
            }
        }
    }
}
