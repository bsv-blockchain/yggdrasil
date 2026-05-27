import Foundation
import GRDB

/// One row in Loom's sidebar (Phase 4+ paints the UI; Phase 3 just persists).
/// May or may not be linked to a GitHub task and/or a coding-agent profile.
struct LoomTab: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "tab"

    enum MainView: String, Codable {
        case agent
        case github
        case diff
    }

    var id: Int64?
    var taskID: Int64?
    var codingAgentID: Int64?
    var position: Int
    var branchName: String
    var worktreePath: String
    var lastMainView: MainView
    var createdAt: Date
    var lastActiveAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case codingAgentID = "coding_agent_id"
        case position
        case branchName = "branch_name"
        case worktreePath = "worktree_path"
        case lastMainView = "last_main_view"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
