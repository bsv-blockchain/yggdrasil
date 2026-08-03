import Foundation
import GRDB

/// A user-configured coding-agent profile. Spawned by `CodingAgentRunner` to
/// produce one tab's worth of work. Phase 3 seeds one default profile (Claude);
/// users add more (Codex, Grok, …) via the debug menu / Phase 8 Preferences.
struct CodingAgent: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "coding_agent"

    var id: Int64?
    var name: String
    var command: String
    /// Decoded form of the `args_json` column. The persisted form is a JSON-encoded
    /// string so we can store arbitrary arg arrays without a join table.
    var args: [String]
    /// Extra environment variables handed to the agent process, decoded form of
    /// the `env_json` column. Same JSON-in-a-column trick as `args`.
    var env: [String: String]
    var isDefault: Bool
    var position: Int
    var createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case command
        case argsJSON = "args_json"
        case envJSON = "env_json"
        case isDefault = "is_default"
        case position
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: Int64?, name: String, command: String, args: [String],
        env: [String: String] = [:],
        isDefault: Bool, position: Int,
        createdAt: Date, updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.args = args
        self.env = env
        self.isDefault = isDefault
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int64.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        command = try container.decode(String.self, forKey: .command)
        let argsJSON = try container.decode(String.self, forKey: .argsJSON)
        args = (try? JSONDecoder().decode([String].self, from: Data(argsJSON.utf8))) ?? []
        let envJSON = try container.decodeIfPresent(String.self, forKey: .envJSON) ?? "{}"
        env = (try? JSONDecoder().decode([String: String].self, from: Data(envJSON.utf8))) ?? [:]
        isDefault = try container.decode(Bool.self, forKey: .isDefault)
        position = try container.decode(Int.self, forKey: .position)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(command, forKey: .command)
        let argsData = try JSONEncoder().encode(args)
        let argsJSON = String(data: argsData, encoding: .utf8) ?? "[]"
        try container.encode(argsJSON, forKey: .argsJSON)
        let envData = try JSONEncoder().encode(env)
        try container.encode(String(data: envData, encoding: .utf8) ?? "{}", forKey: .envJSON)
        try container.encode(isDefault, forKey: .isDefault)
        try container.encode(position, forKey: .position)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
