import Foundation
import GRDB

/// Typed string get/set over the `setting` key-value table.
struct SettingsStore: Sendable {
    let database: YggdrasilDatabase

    func get(forKey key: String) throws -> String? {
        try database.queue.read { db in
            try Setting.fetchOne(db, key: key)?.value
        }
    }

    func set(_ value: String, forKey key: String) throws {
        try database.queue.write { db in
            try Setting(key: key, value: value).save(db)
        }
    }
}
