import GRDB

/// Schema migrations for the Loom database. New migrations append; never edit history.
enum Migrations {
    static func register() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            // setting: simple key/value table used by SettingsStore and ETagStore.
            try db.create(table: "setting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            // repo: tracked GitHub repositories.
            try db.create(table: "repo") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("owner", .text).notNull()
                t.column("name", .text).notNull()
                t.column("default_branch", .text).notNull()
                t.column("local_main_path", .text)
                t.column("added_at", .datetime).notNull()
                t.uniqueKey(["owner", "name"])
            }

            // task: issues and PRs assigned to the user.
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

            // task_assignee: many-to-one to task.
            try db.create(table: "task_assignee") { t in
                t.column("task_id", .integer).notNull()
                    .references("task", onDelete: .cascade)
                t.column("login", .text).notNull()
                t.primaryKey(["task_id", "login"])
            }

            // github_status: 1:1 with task.
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

        return migrator
    }
}
