import Foundation
import GRDB

/// The task lists behind the Assigned Tasks and Review Requests windows, and
/// the sidebar badges that count them. One definition, so a list and its
/// count can't drift apart. Tasks already open as a tab (or linked to one as
/// an issue tab's PR) are left out.
enum TaskQueries {
    /// Task ids already shadowed by a tab — as the tab's primary task OR as an
    /// issue tab's linked PR (`pr_task_id`).
    private static let openedTaskIDsSQL = """
    SELECT task_id FROM tab WHERE task_id IS NOT NULL
    UNION SELECT pr_task_id FROM tab WHERE pr_task_id IS NOT NULL
    """

    /// PRs to review: review-requested, plus assigned but not authored. A PR
    /// I both wrote and was asked to review lands here too.
    private static let reviewPRFilter = """
    task.type = 'pr'
      AND (
        task.id IN (SELECT task_id FROM pr_review_request)
     OR (task.id IN (SELECT task_id FROM pr_assigned)
         AND task.id NOT IN (SELECT task_id FROM pr_authored))
      )
    """

    private static let toReviewFilter = """
    \(reviewPRFilter)
      AND task.id NOT IN (\(openedTaskIDsSQL))
    """

    /// Whether the task is a PR to review, as Review Requests defines it,
    /// whether or not a tab has it already.
    static func isToReview(_ db: Database, taskID: Int64) throws -> Bool {
        try Bool.fetchOne(
            db, sql: "SELECT EXISTS (SELECT 1 FROM task WHERE task.id = ? AND \(reviewPRFilter))", arguments: [taskID]
        ) ?? false
    }

    /// Issues assigned to me (the sync only mirrors those) plus PRs I wrote.
    private static let assignedFilter = """
    (task.type = 'issue' OR task.id IN (SELECT task_id FROM pr_authored))
      AND task.id NOT IN (\(openedTaskIDsSQL))
    """

    static func toReview(_ db: Database) throws -> [YggdrasilTask] {
        try YggdrasilTask.fetchAll(
            db,
            sql: "SELECT task.* FROM task WHERE \(toReviewFilter) ORDER BY task.updated_at DESC"
        )
    }

    static func toReviewCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE \(toReviewFilter)") ?? 0
    }

    static func assigned(_ db: Database) throws -> [YggdrasilTask] {
        try YggdrasilTask.fetchAll(
            db,
            sql: "SELECT task.* FROM task WHERE \(assignedFilter) ORDER BY task.updated_at DESC"
        )
    }

    static func assignedCount(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM task WHERE \(assignedFilter)") ?? 0
    }
}
