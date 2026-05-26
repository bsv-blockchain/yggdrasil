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
        }

        return migrator
    }
}
