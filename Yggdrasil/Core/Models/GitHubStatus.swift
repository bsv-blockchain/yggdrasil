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
    // Legacy (v1): never populated; superseded by the `*Total` fields below.
    var unreadCommentsCount: Int
    var lastSeenCommentID: Int64?
    var fetchedAt: Date

    // v7 — current PR activity, refreshed each sync.
    var commentsReviewsTotal: Int
    var commitsTotal: Int
    var headSHA: String?
    // v7 — baseline snapshotted when the user last opened the tab. nil until a
    // sync first seeds it (so a freshly-tracked PR isn't flagged as "new").
    var seenCommentsReviewsTotal: Int?
    var seenCommitsTotal: Int?
    var seenHeadSHA: String?

    // v9 — per-viewer review state, for the "outstanding action" REVIEW pill.
    // Derived from GitHub each sync; independent of whether the tab was opened.
    var viewerLatestReviewState: String?
    var viewerReviewedHeadSHA: String?
    var unresolvedThreadsAwaitingViewer: Int = 0

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
        case commentsReviewsTotal = "comments_reviews_total"
        case commitsTotal = "commits_total"
        case headSHA = "head_sha"
        case seenCommentsReviewsTotal = "seen_comments_reviews_total"
        case seenCommitsTotal = "seen_commits_total"
        case seenHeadSHA = "seen_head_sha"
        case viewerLatestReviewState = "viewer_latest_review_state"
        case viewerReviewedHeadSHA = "viewer_reviewed_head_sha"
        case unresolvedThreadsAwaitingViewer = "unresolved_threads_awaiting_viewer"
    }

    // MARK: - Activity since last opened (pure)

    /// Comments + reviews added since the user last opened the tab. 0 when
    /// unseen (no baseline yet) or nothing new.
    var newCommentsSinceSeen: Int {
        guard let seen = seenCommentsReviewsTotal else { return 0 }
        return max(0, commentsReviewsTotal - seen)
    }

    /// New commits since last opened (count for the chip; 0 on a rebase/amend
    /// that kept the count — `headChangedSinceSeen` still catches those).
    var newCommitsSinceSeen: Int {
        guard let seen = seenCommitsTotal else { return 0 }
        return max(0, commitsTotal - seen)
    }

    /// The PR head moved since last opened — catches rebases/force-pushes that
    /// don't change the commit count.
    var headChangedSinceSeen: Bool {
        guard let seen = seenHeadSHA, let head = headSHA else { return false }
        return head != seen
    }

    /// There's a next action on this PR: the author pushed commits or someone
    /// commented since the user last looked.
    var hasActivitySinceSeen: Bool {
        newCommentsSinceSeen > 0 || newCommitsSinceSeen > 0 || headChangedSinceSeen
    }

    // MARK: - Outstanding review action (pure)

    /// The viewer has reviewed the current head — submitted a review of any kind
    /// (approve / comment / request-changes) against the commit that is now
    /// HEAD. Once they have, the ball is in the author's court until the author
    /// pushes again; a review of an older head (commits landed since) doesn't
    /// count.
    var reviewCoversCurrentHead: Bool {
        viewerLatestReviewState != nil
            && viewerReviewedHeadSHA != nil
            && viewerReviewedHeadSHA == headSHA
    }

    /// Whether there's an outstanding review action for the viewer: they haven't
    /// reviewed the current head (never reviewed, or the author pushed new
    /// commits since their last review), or an unresolved thread's last comment
    /// is someone else's (awaiting their reply). The viewer's OWN activity —
    /// posting a comment, review, or reply — never flips this on. Drives the
    /// amber REVIEW pill; derived purely from GitHub, so opening the tab does
    /// not clear it.
    var reviewActionOutstanding: Bool {
        !reviewCoversCurrentHead || unresolvedThreadsAwaitingViewer > 0
    }
}
