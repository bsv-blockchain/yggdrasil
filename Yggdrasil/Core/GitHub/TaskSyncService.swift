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
