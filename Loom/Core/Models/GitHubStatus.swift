import Foundation
import GRDB

/// One row per task. Periodically refreshed from GitHub.
struct GitHubStatus: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "github_status"

    var taskID: Int64
    var ciState: String?
    var ciURL: String?
    var mergeable: Bool?
    var mergeableState: String?
    var reviewState: String?
    var unreadCommentsCount: Int
    var lastSeenCommentID: Int64?
    var fetchedAt: Date

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case ciState = "ci_state"
        case ciURL = "ci_url"
        case mergeable
        case mergeableState = "mergeable_state"
        case reviewState = "review_state"
        case unreadCommentsCount = "unread_comments_count"
        case lastSeenCommentID = "last_seen_comment_id"
        case fetchedAt = "fetched_at"
    }
}
