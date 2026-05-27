import Foundation
import GRDB

/// A GitHub issue or PR assigned to the user.
///
/// Named `YggdrasilTask` rather than `Task` to avoid collision with Swift Concurrency's
/// `_Concurrency.Task`. The database table name remains `task` per spec §3.2.
struct YggdrasilTask: Codable, FetchableRecord, MutablePersistableRecord, Equatable {
    static let databaseTableName = "task"

    enum Kind: String, Codable {
        case issue
        case pullRequest = "pr"
    }

    enum State: String, Codable {
        case open
        case closed
        case merged
    }

    var id: Int64?
    var repoID: Int64
    var type: Kind
    var number: Int
    var title: String
    var body: String?
    var state: State
    var authorLogin: String
    var githubURL: String
    var apiURL: String
    var createdAt: Date
    var updatedAt: Date
    var lastSyncedAt: Date
    var etag: String?
    /// JSON-encoded `[Label]` from `RawTask.Label`. Stored as text so the
    /// model schema doesn't need a join table for a single read site
    /// (the issue-details picker).
    var labelsJSON: String = "[]"
    var milestoneTitle: String?

    /// Convenience parser for the JSON-blob column.
    var labels: [Label] {
        (try? JSONDecoder().decode([Label].self, from: Data(labelsJSON.utf8))) ?? []
    }

    struct Label: Codable, Hashable {
        let name: String
        let color: String
    }

    enum CodingKeys: String, CodingKey {
        case id
        case repoID = "repo_id"
        case type
        case number
        case title
        case body
        case state
        case authorLogin = "author_login"
        case githubURL = "github_url"
        case apiURL = "api_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case lastSyncedAt = "last_synced_at"
        case etag
        case labelsJSON = "labels_json"
        case milestoneTitle = "milestone_title"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
