import Foundation
import GRDB

/// One row in Yggdrasil's sidebar (Phase 4+ paints the UI; Phase 3 just persists).
/// May or may not be linked to a GitHub task and/or a coding-agent profile.
struct YggdrasilTab: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "tab"

    enum MainView: String, Codable {
        case agent
        case github
        case diff
    }

    /// How far the tab's worktree has got. A tab is inserted the instant you
    /// click, so it exists well before `git fetch` + `git worktree add` have
    /// finished — the row and the main pane render from this rather than
    /// pretending an empty directory is a working session.
    /// `unknown` default on decode: a surprise value in the column would
    /// otherwise throw out of `store.list()`, which `TabsModel.reload` swallows
    /// — rendering an empty sidebar with no error anywhere.
    enum PreparationState: String, Codable {
        /// Queued behind another preparation in the same repo.
        case pending
        /// Its git work is running now.
        case preparing
        /// Worktree is on disk; the agent can start.
        case ready
        /// Git failed; `preparationError` says why and the user can retry.
        case failed

        init(from decoder: Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            self = PreparationState(rawValue: raw) ?? .ready
        }
    }

    var id: Int64?
    var taskID: Int64?
    /// PR task linked to this tab when `taskID` is an issue. Lets the row show
    /// the issue and its implementing PR together. nil for PR-only / ad-hoc tabs.
    var prTaskID: Int64?
    var codingAgentID: Int64?
    var position: Int
    var branchName: String
    var worktreePath: String
    var lastMainView: MainView
    var createdAt: Date
    var lastActiveAt: Date
    var preparationState: PreparationState = .ready
    var preparationError: String?

    /// Whether the worktree is usable — the one question the UI actually asks.
    var isReady: Bool {
        preparationState == .ready
    }

    enum CodingKeys: String, CodingKey {
        case id
        case taskID = "task_id"
        case prTaskID = "pr_task_id"
        case codingAgentID = "coding_agent_id"
        case position
        case branchName = "branch_name"
        case worktreePath = "worktree_path"
        case lastMainView = "last_main_view"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
        case preparationState = "preparation_state"
        case preparationError = "preparation_error"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
