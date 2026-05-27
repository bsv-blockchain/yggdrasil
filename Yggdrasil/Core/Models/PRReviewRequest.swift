import Foundation
import GRDB

/// Row in `pr_review_request`: the viewer has been requested to review the
/// linked PR. Written by `TaskSyncService` from the GitHub search endpoint
/// `is:pr is:open review-requested:@me`. Lookups are PK-by-task_id.
struct PRReviewRequest: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "pr_review_request"

    var taskID: Int64
    var requestedAt: Date

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case requestedAt = "requested_at"
    }
}
