import Foundation
import GRDB

/// Typed CRUD over the `session_state` table. Used by `CodingAgentRunner` to
/// persist what's running where so a restart can offer to resume the same agent.
struct SessionStateStore {
    let database: LoomDatabase

    func get(tabID: Int64) throws -> SessionState? {
        try database.queue.read { db in try SessionState.fetchOne(db, key: tabID) }
    }

    /// Upsert: starts (or restarts) a session for `tabID`. `pty_started_at` is reset
    /// to "now"; `pty_ended_at` and `last_known_exit_code` are cleared.
    @discardableResult
    func start(tabID: Int64, cwd: String, command: String, args: [String]) throws -> SessionState {
        let state = SessionState(
            tabID: tabID, cwd: cwd, agentCommand: command, agentArgs: args,
            lastKnownExitCode: nil, ptyStartedAt: Date(), ptyEndedAt: nil
        )
        try database.queue.write { db in try state.save(db) }
        return state
    }

    /// Records the exit code + pty_ended_at on an existing session row. No-op if
    /// no row exists for `tabID`.
    func end(tabID: Int64, exitCode: Int32) throws {
        try database.queue.write { db in
            try db.execute(
                sql: """
                UPDATE session_state
                SET last_known_exit_code = ?, pty_ended_at = ?
                WHERE tab_id = ?
                """,
                arguments: [exitCode, Date(), tabID]
            )
        }
    }
}
