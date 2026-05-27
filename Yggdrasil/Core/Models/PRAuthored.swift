import Foundation
import GRDB

/// Row in `pr_authored`: the viewer authored this PR. Written by
/// `TaskSyncService` from the GitHub search endpoint
/// `is:pr is:open author:@me`. PK-by-task_id, mirrors `PRReviewRequest`.
struct PRAuthored: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "pr_authored"

    var taskID: Int64
    var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case recordedAt = "recorded_at"
    }
}

/// Row in `pr_assigned`: the viewer is in the PR's assignees list. Written
/// alongside the existing assigned-issues sync — every PR returned from
/// `/issues?filter=assigned` is mirrored here so the Review picker can
/// distinguish "assigned to me as assignee" from "review-requested".
struct PRAssigned: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "pr_assigned"

    var taskID: Int64
    var recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case recordedAt = "recorded_at"
    }
}
