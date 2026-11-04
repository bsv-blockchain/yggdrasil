import Foundation
import GRDB

enum CodingAgentStoreError: Error, Equatable {
    case agentNotFound(Int64)
}

/// Typed CRUD over the `coding_agent` table.
struct CodingAgentStore {
    let database: YggdrasilDatabase

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
    func add(
        name: String, command: String, args: [String], env: [String: String] = [:]
    ) throws -> CodingAgent {
        try database.queue.write { db in
            let maxPosition = try Int.fetchOne(
                db, sql: "SELECT COALESCE(MAX(position), -1) FROM coding_agent"
            ) ?? -1
            let now = Date()
            var agent = CodingAgent(
                id: nil, name: name, command: command, args: args, env: env,
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

    /// In-place edit of name/command/args/env. Refreshes `updated_at`.
    ///
    /// A nil argument leaves that column alone; a non-nil one replaces it
    /// wholesale (so `env: [:]` clears the environment). Callers pass only what
    /// they changed — writing the whole row from a snapshot means two commits
    /// landing close together, e.g. a text field committing as the Apply button
    /// steals focus, each carry the other's stale values and one reverts the
    /// other.
    func update(
        id: Int64,
        name: String? = nil,
        command: String? = nil,
        args: [String]? = nil,
        env: [String: String]? = nil
    ) throws {
        try database.queue.write { db in
            let count = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM coding_agent WHERE id = ?", arguments: [id]
            ) ?? 0
            guard count == 1 else {
                throw CodingAgentStoreError.agentNotFound(id)
            }

            var assignments: [String] = []
            var values: [DatabaseValueConvertible] = []
            if let name {
                assignments.append("name = ?")
                values.append(name)
            }
            if let command {
                assignments.append("command = ?")
                values.append(command)
            }
            if let args {
                let data = try JSONEncoder().encode(args)
                assignments.append("args_json = ?")
                values.append(String(data: data, encoding: .utf8) ?? "[]")
            }
            if let env {
                let data = try JSONEncoder().encode(env)
                assignments.append("env_json = ?")
                values.append(String(data: data, encoding: .utf8) ?? "{}")
            }
            guard !assignments.isEmpty else { return }

            assignments.append("updated_at = ?")
            values.append(Date())
            values.append(id)
            try db.execute(
                sql: "UPDATE coding_agent SET \(assignments.joined(separator: ", ")) WHERE id = ?",
                arguments: StatementArguments(values)
            )
        }
    }
}
