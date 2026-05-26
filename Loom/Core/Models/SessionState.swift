import Foundation
import GRDB

/// One row per tab. Records what coding agent was last spawned in this tab so a
/// restart can offer to resume the same one. Cascade-deleted with its parent tab.
struct SessionState: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "session_state"

    var tabID: Int64
    var cwd: String
    var agentCommand: String
    /// Decoded form of `agent_args_json`. Persisted as a JSON string for the same
    /// reason as `CodingAgent.args` — arbitrary array, no join table.
    var agentArgs: [String]
    var lastKnownExitCode: Int32?
    var ptyStartedAt: Date
    var ptyEndedAt: Date?

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case cwd
        case agentCommand = "agent_command"
        case agentArgsJSON = "agent_args_json"
        case lastKnownExitCode = "last_known_exit_code"
        case ptyStartedAt = "pty_started_at"
        case ptyEndedAt = "pty_ended_at"
    }

    init(
        tabID: Int64, cwd: String, agentCommand: String, agentArgs: [String],
        lastKnownExitCode: Int32?, ptyStartedAt: Date, ptyEndedAt: Date?
    ) {
        self.tabID = tabID
        self.cwd = cwd
        self.agentCommand = agentCommand
        self.agentArgs = agentArgs
        self.lastKnownExitCode = lastKnownExitCode
        self.ptyStartedAt = ptyStartedAt
        self.ptyEndedAt = ptyEndedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decode(Int64.self, forKey: .tabID)
        cwd = try container.decode(String.self, forKey: .cwd)
        agentCommand = try container.decode(String.self, forKey: .agentCommand)
        let json = try container.decode(String.self, forKey: .agentArgsJSON)
        agentArgs = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        lastKnownExitCode = try container.decodeIfPresent(Int32.self, forKey: .lastKnownExitCode)
        ptyStartedAt = try container.decode(Date.self, forKey: .ptyStartedAt)
        ptyEndedAt = try container.decodeIfPresent(Date.self, forKey: .ptyEndedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tabID, forKey: .tabID)
        try container.encode(cwd, forKey: .cwd)
        try container.encode(agentCommand, forKey: .agentCommand)
        let argsData = try JSONEncoder().encode(agentArgs)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        try container.encode(argsJSON, forKey: .agentArgsJSON)
        try container.encodeIfPresent(lastKnownExitCode, forKey: .lastKnownExitCode)
        try container.encode(ptyStartedAt, forKey: .ptyStartedAt)
        try container.encodeIfPresent(ptyEndedAt, forKey: .ptyEndedAt)
    }
}
