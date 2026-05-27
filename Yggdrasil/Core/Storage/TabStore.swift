import Foundation
import GRDB

enum TabStoreError: Error, Equatable {
    /// Reorder was given an `ids` list whose set doesn't match the actual rows in
    /// the table (missing ids, extra ids, or duplicates).
    case reorderIDMismatch
}

/// Typed CRUD over the `tab` table. The sidebar (Phase 4+) is the only customer
/// for now; Phase 6's TabStatus aggregator will later piggy-back on `list()`.
struct TabStore {
    let database: YggdrasilDatabase

    func list() throws -> [YggdrasilTab] {
        try database.queue.read { db in
            try YggdrasilTab.fetchAll(db, sql: "SELECT * FROM tab ORDER BY position ASC, id ASC")
        }
    }

    func get(id: Int64) throws -> YggdrasilTab? {
        try database.queue.read { db in try YggdrasilTab.fetchOne(db, key: id) }
    }

    /// Inserts a new tab at the end (position = max(position) + 1). Returns the
    /// row with its auto-assigned id and position.
    @discardableResult
    func insert(
        branchName: String,
        worktreePath: String,
        agentID: Int64?,
        taskID: Int64?
    ) throws -> YggdrasilTab {
        try database.queue.write { db in
            let maxPosition = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) FROM tab"
            ) ?? -1
            let now = Date()
            var tab = YggdrasilTab(
                id: nil, taskID: taskID, codingAgentID: agentID,
                position: maxPosition + 1,
                branchName: branchName, worktreePath: worktreePath,
                lastMainView: .agent, createdAt: now, lastActiveAt: now
            )
            try tab.insert(db)
            return tab
        }
    }

    func delete(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM tab WHERE id = ?", arguments: [id])
        }
    }

    /// Rewrites `position` for every tab in the given order. Throws
    /// `.reorderIDMismatch` if `ids` doesn't exactly match the current set of
    /// row ids (no duplicates, no missing, no extra). Atomic.
    func reorder(ids: [Int64]) throws {
        try database.queue.write { db in
            let actual = try Set(Int64.fetchAll(db, sql: "SELECT id FROM tab"))
            let requested = Set(ids)
            guard actual == requested, ids.count == actual.count else {
                throw TabStoreError.reorderIDMismatch
            }
            for (position, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE tab SET position = ? WHERE id = ?",
                    arguments: [position, id]
                )
            }
        }
    }

    /// Updates `tab.last_main_view` for a single row.
    func setLastMainView(id: Int64, view: YggdrasilTab.MainView) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE tab SET last_main_view = ?, last_active_at = ? WHERE id = ?",
                arguments: [view.rawValue, Date(), id]
            )
        }
    }

    func touchLastActiveAt(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(
                sql: "UPDATE tab SET last_active_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }
}
