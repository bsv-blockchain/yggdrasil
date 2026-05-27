import Foundation
import GRDB

/// Schema migrations for the Yggdrasil database. New migrations append; never edit history.
enum Migrations {
    static func register() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1", migrate: v1)
        migrator.registerMigration("v2", migrate: v2)
        migrator.registerMigration("v3", migrate: v3)
        return migrator
    }

    // MARK: - v3 — PR review-requested marker
    //
    // A row here means the current viewer was requested to review this PR
    // (the linked task row is the PR itself; review-requested is an
    // orthogonal status to assignment, so it gets its own table — same
    // shape as task_assignee).
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
        let argsJSON = String(
            data: try JSONEncoder().encode(["--dangerously-skip-permissions"]),
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
