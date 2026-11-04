import Foundation
import GRDB

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

    /// Re-resolve a task id at the moment it's used, reviving the row if it
    /// has been deleted meanwhile.
    ///
    /// The task pickers hold a snapshot of the list from when they loaded.
    /// Between that and the user clicking a row, `deleteStaleTasks` can remove
    /// the task: closing a tab drops the only protection it had (the prune
    /// keeps tasks referenced by a live tab), and a review the user just
    /// finished is no longer in GitHub's review-requested results — so the very
    /// sync that `performRemoval` fires on close deletes it. Inserting a tab
    /// against that dead id fails the `tab.task_id` foreign key.
    ///
    /// Matching is on the natural key `(repo_id, type, number)`, not the id, so
    /// a row the sync re-imported under a fresh id is reused rather than
    /// duplicated into a UNIQUE violation.
    static func resolveOrReviveTask(db: Database, snapshot: YggdrasilTask) throws -> Int64 {
        if let live = try Int64.fetchOne(
            db,
            sql: "SELECT id FROM task WHERE repo_id = ? AND type = ? AND number = ?",
            arguments: [snapshot.repoID, snapshot.type.rawValue, snapshot.number]
        ) {
            return live
        }
        // Gone. Put the snapshot back under a fresh id — the old one may have
        // been handed out again by AUTOINCREMENT in the meantime. The next sync
        // overwrites it with current data if GitHub still knows about it.
        var revived = snapshot
        revived.id = nil
        try revived.insert(db)
        return revived.id!
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
            viewerReviewRequested: detail.viewerReviewRequested,
            viewerDidAuthorPR: detail.viewerDidAuthor,
            viewerReviewRequestedAt: detail.viewerReviewRequestedAt
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
        // Both columns: `pr_task_id` is the PR manually linked to an issue
        // tab. Protecting only `task_id` let that PR be pruned underneath the
        // tab, and because the FK is ON DELETE SET NULL the link just
        // disappeared instead of failing loudly.
        let linkedTaskIDs = try Int64.fetchSet(
            db,
            sql: """
            SELECT task_id FROM tab WHERE task_id IS NOT NULL
            UNION
            SELECT pr_task_id FROM tab WHERE pr_task_id IS NOT NULL
            """
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
