import Foundation
import GRDB

/// Schema migrations for the Yggdrasil database. New migrations append; never edit history.
enum Migrations {
    static func register() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2", migrate: v2)
        migrator.registerMigration("v3", migrate: v3)
        migrator.registerMigration("v4", migrate: v4)
        migrator.registerMigration("v5", migrate: v5)
        migrator.registerMigration("v6", migrate: v6)
        migrator.registerMigration("v7", migrate: v7)
        migrator.registerMigration("v8", migrate: v8)
        migrator.registerMigration("v9", migrate: v9)
        migrator.registerMigration("v10", migrate: v10)
        return migrator
    }

    // MARK: - v10 — Engagement/commit timestamps for the REVIEW pill

    ///
    /// The amber pill now fires only when the author pushed a commit *after* the
    /// viewer last engaged (their last review or comment) — so a push the viewer
    /// has already commented on doesn't nag. Store the viewer's last-engagement
    /// time and the head commit time to compare each sync.
    private static func v10(_ db: Database) throws {
        try db.alter(table: "github_status") { table in
            table.add(column: "viewer_last_engagement_at", .datetime)
            table.add(column: "head_committed_at", .datetime)
        }
    }

    // MARK: - v9 — Per-viewer review state (outstanding-action REVIEW pill)

    ///
    /// The amber REVIEW pill now means "there's a review action for you on this
    /// PR", derived from GitHub, rather than "activity since you last opened the
    /// tab". Store the viewer's latest review state and the commit it covered
    /// (to detect a stale approval after new pushes), plus the count of
    /// unresolved threads whose last comment isn't the viewer's.
    private static func v9(_ db: Database) throws {
        try db.alter(table: "github_status") { table in
            table.add(column: "viewer_latest_review_state", .text)
            table.add(column: "viewer_reviewed_head_sha", .text)
            table.add(column: "unresolved_threads_awaiting_viewer", .integer)
                .notNull().defaults(to: 0)
        }
    }

    // MARK: - v8 — Fork upstream tracking

    ///
    /// A fork carries no issues of its own; they live in the parent/source repo.
    /// Storing the resolved source owner/name lets sync attribute upstream-owned
    /// issues + PRs back to this fork's `repo_id`, transparently. `upstream_checked_at`
    /// distinguishes "resolved, not a fork" (owner/name NULL, timestamp set) from
    /// "not yet probed" (timestamp NULL) so non-forks aren't re-probed every sync.
    private static func v8(_ db: Database) throws {
        try db.alter(table: "repo") { table in
            table.add(column: "upstream_owner", .text)
            table.add(column: "upstream_name", .text)
            table.add(column: "upstream_checked_at", .datetime)
        }
    }

    // MARK: - v7 — PR activity tracking (review "your move" signal)

    ///
    /// Track the PR's current comment+review count, commit count, and head SHA,
    /// plus a "seen" baseline snapshotted when the user opens the tab. The
    /// sidebar compares current vs seen to flag review tabs whose PR gained new
    /// commits or comments since the user last looked (amber REVIEW pill). The
    /// legacy `unread_comments_count`/`last_seen_comment_id` columns were never
    /// populated (always 0); these supersede them.
    private static func v7(_ db: Database) throws {
        try db.alter(table: "github_status") { table in
            table.add(column: "comments_reviews_total", .integer).notNull().defaults(to: 0)
            table.add(column: "commits_total", .integer).notNull().defaults(to: 0)
            table.add(column: "head_sha", .text)
            // Baseline captured on tab open; NULL until first seeded by sync.
            table.add(column: "seen_comments_reviews_total", .integer)
            table.add(column: "seen_commits_total", .integer)
            table.add(column: "seen_head_sha", .text)
        }
    }

    // MARK: - v6 — Linked PR on a tab

    ///
    /// A tab's `task_id` is its primary task (an issue, or a PR for PR-only
    /// tabs). `pr_task_id` lets an issue tab additionally carry the PR that
    /// implements it, so the sidebar row can show both (issue + PR) instead
    /// of "Link PR" replacing the issue. Nullable; ON DELETE SET NULL so a
    /// pruned PR task just drops the link.
    private static func v6(_ db: Database) throws {
        try db.alter(table: "tab") { table in
            table.add(column: "pr_task_id", .integer)
                .references("task", onDelete: .setNull)
        }
    }

    // MARK: - v5 — Label + milestone metadata on `task`

    ///
    /// Powers the issue-details picker (table view of issues assigned to me).
    /// Labels live as a JSON-encoded array of `{ name, color }` on the row so
    /// we don't need a separate join table for a feature that only renders
    /// them in one place. `milestone_title` is the single string GitHub
    /// returns for the milestone's title (nullable).
    private static func v5(_ db: Database) throws {
        try db.alter(table: "task") { table in
            table.add(column: "labels_json", .text).notNull().defaults(to: "[]")
            table.add(column: "milestone_title", .text)
        }
    }

    // MARK: - v4 — Authored/assigned PR markers

    ///
    /// The Open Assigned picker now shows issues-assigned-to-me plus PRs
    /// I-authored. The Review picker shows PRs review-requested-from-me or
    /// PRs assigned-to-me (without being authored by me). Two new membership
    /// tables, same shape as the existing pr_review_request: a row's mere
    /// presence is the signal.
    private static func v4(_ db: Database) throws {
        try db.create(table: "pr_authored") { table in
            table.column("task_id", .integer)
                .primaryKey()
                .references("task", onDelete: .cascade)
            table.column("recorded_at", .datetime).notNull()
        }
        try db.create(table: "pr_assigned") { table in
            table.column("task_id", .integer)
                .primaryKey()
                .references("task", onDelete: .cascade)
            table.column("recorded_at", .datetime).notNull()
        }
    }

    // MARK: - v3 — PR review-requested marker

    ///
    /// A row here means the current viewer was requested to review this PR
    /// (the linked task row is the PR itself; review-requested is an
    /// orthogonal status to assignment, so it gets its own table — same
    /// shape as task_assignee).
    private static func v3(_ db: Database) throws {
        try db.create(table: "pr_review_request") { table in
            table.column("task_id", .integer)
                .primaryKey()
                .references("task", onDelete: .cascade)
            table.column("requested_at", .datetime).notNull()
        }
    }

    // MARK: - v1 (Phase 1)

    private static func v1(_ db: Database) throws {
        try db.create(table: "setting") { t in
            t.column("key", .text).primaryKey()
            t.column("value", .text).notNull()
        }

        try db.create(table: "repo") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("owner", .text).notNull()
            t.column("name", .text).notNull()
            t.column("default_branch", .text).notNull()
            t.column("local_main_path", .text)
            t.column("added_at", .datetime).notNull()
            t.uniqueKey(["owner", "name"])
        }

        try db.create(table: "task") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("repo_id", .integer).notNull()
                .references("repo", onDelete: .cascade)
            t.column("type", .text).notNull() // "issue" | "pr"
            t.column("number", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("body", .text)
            t.column("state", .text).notNull() // "open" | "closed" | "merged"
            t.column("author_login", .text).notNull()
            t.column("github_url", .text).notNull()
            t.column("api_url", .text).notNull()
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("last_synced_at", .datetime).notNull()
            t.column("etag", .text)
            t.uniqueKey(["repo_id", "type", "number"])
        }

        try db.create(table: "task_assignee") { t in
            t.column("task_id", .integer).notNull()
                .references("task", onDelete: .cascade)
            t.column("login", .text).notNull()
            t.primaryKey(["task_id", "login"])
        }

        try db.create(table: "github_status") { t in
            t.column("task_id", .integer).primaryKey()
                .references("task", onDelete: .cascade)
            t.column("ci_state", .text)
            t.column("ci_url", .text)
            t.column("mergeable", .boolean)
            t.column("mergeable_state", .text)
            t.column("review_state", .text)
            t.column("unread_comments_count", .integer).notNull().defaults(to: 0)
            t.column("last_seen_comment_id", .integer)
            t.column("fetched_at", .datetime).notNull()
        }
    }

    // MARK: - v2 (Phase 3) — coding agents, tabs, session state

    private static func v2(_ db: Database) throws {
        try db.create(table: "coding_agent") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("command", .text).notNull()
            t.column("args_json", .text).notNull().defaults(to: "[]")
            t.column("is_default", .boolean).notNull().defaults(to: false)
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }

        try db.create(table: "tab") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("task_id", .integer)
                .references("task", onDelete: .setNull)
            t.column("coding_agent_id", .integer)
                .references("coding_agent", onDelete: .setNull)
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("branch_name", .text).notNull()
            t.column("worktree_path", .text).notNull()
            t.column("last_main_view", .text).notNull().defaults(to: "agent")
            t.column("created_at", .datetime).notNull()
            t.column("last_active_at", .datetime).notNull()
        }

        try db.create(table: "session_state") { t in
            t.column("tab_id", .integer).primaryKey()
                .references("tab", onDelete: .cascade)
            t.column("cwd", .text).notNull()
            t.column("agent_command", .text).notNull()
            t.column("agent_args_json", .text).notNull().defaults(to: "[]")
            t.column("last_known_exit_code", .integer)
            t.column("pty_started_at", .datetime).notNull()
            t.column("pty_ended_at", .datetime)
        }

        try seedDefaultClaudeAgent(db)
    }

    private static func seedDefaultClaudeAgent(_ db: Database) throws {
        let now = Date()
        let argsJSON = try String(
            data: JSONEncoder().encode(["--dangerously-skip-permissions"]),
            encoding: .utf8
        ) ?? "[]"
        try db.execute(
            sql: """
            INSERT INTO coding_agent (name, command, args_json, is_default, position, created_at, updated_at)
            VALUES (?, ?, ?, 1, 0, ?, ?)
            """,
            arguments: ["Claude", "claude", argsJSON, now, now]
        )
    }
}
