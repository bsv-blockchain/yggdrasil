import Foundation
import GRDB

enum CodingAgentStoreError: Error, Equatable {
    case agentNotFound(Int64)
}

/// Typed CRUD over the `coding_agent` table.
struct CodingAgentStore {
    let database: LoomDatabase

    func list() throws -> [CodingAgent] {
        try database.queue.read { db in
            try CodingAgent.fetchAll(db, sql: "SELECT * FROM coding_agent ORDER BY position ASC")
        }
    }

    func get(id: Int64) throws -> CodingAgent? {
        try database.queue.read { db in try CodingAgent.fetchOne(db, key: id) }
    }

    func getDefault() throws -> CodingAgent? {
        try database.queue.read { db in
            try CodingAgent.fetchOne(db, sql: "SELECT * FROM coding_agent WHERE is_default = 1 LIMIT 1")
        }
    }

    /// Inserts a new profile at the end of the list (max(position) + 1).
    func add(name: String, command: String, args: [String]) throws -> CodingAgent {
        try database.queue.write { db in
            let maxPosition = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) FROM coding_agent"
            ) ?? -1
            let now = Date()
            var agent = CodingAgent(
                id: nil, name: name, command: command, args: args,
                isDefault: false, position: maxPosition + 1,
                createdAt: now, updatedAt: now
            )
            try agent.insert(db)
            return agent
        }
    }

    func remove(id: Int64) throws {
        try database.queue.write { db in
            try db.execute(sql: "DELETE FROM coding_agent WHERE id = ?", arguments: [id])
        }
    }

    /// Atomically clears `is_default` on every row and sets it on the requested one.
    func setDefault(id: Int64) throws {
        try database.queue.write { db in
            // Confirm the target exists; throw if not so the caller sees a clean error
            // rather than a silent no-op.
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM coding_agent WHERE id = ?", arguments: [id]
            ) ?? 0
            guard count == 1 else {
                throw CodingAgentStoreError.agentNotFound(id)
            }
            try db.execute(sql: "UPDATE coding_agent SET is_default = 0")
            try db.execute(
                sql: "UPDATE coding_agent SET is_default = 1, updated_at = ? WHERE id = ?",
                arguments: [Date(), id]
            )
        }
    }

    /// In-place edit of name/command/args. Refreshes `updated_at`.
    func update(id: Int64, name: String, command: String, args: [String]) throws {
        try database.queue.write { db in
            let argsData = try JSONEncoder().encode(args)
            let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
            let now = Date()
            let rowsAffected = try db.execute(
                sql: """
                UPDATE coding_agent
                SET name = ?, command = ?, args_json = ?, updated_at = ?
                WHERE id = ?
                """,
                arguments: [name, command, argsJSON, now, id]
            )
            _ = rowsAffected
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM coding_agent WHERE id = ?", arguments: [id]
            ) ?? 0
            guard count == 1 else {
                throw CodingAgentStoreError.agentNotFound(id)
            }
        }
    }
}
