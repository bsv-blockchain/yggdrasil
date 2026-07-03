import Foundation

/// Pure view model for one sidebar row. Lives outside SwiftUI so the rendering
/// logic is unit-testable. Phase 6 will plumb `statusIcon` from `TabStatus`.
struct TabRowViewModel: Equatable {
    enum StatusIcon: Equatable {
        case idle
        case running
        case awaitingInput
        case errored
        case dirty
        case unread
        case ciFailing
    }

    enum TrailingBadge: Equatable {
        case none
        case prNumber(Int)
        case issueNumber(Int)
    }

    /// GitHub PR review decision, surfaced as a coloured dot on the row.
    /// nil for non-PR tabs and PRs with no review activity (so no dot shows).
    enum ReviewDot: Equatable {
        case approved // green
        case changesRequested // red
        case reviewRequired // amber

        init?(reviewState: String?) {
            switch reviewState?.uppercased() {
            case "APPROVED": self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "REVIEW_REQUIRED": self = .reviewRequired
            default: return nil
            }
        }

        /// GitHub-worded label for the hover tooltip.
        var label: String {
            switch self {
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .reviewRequired: "Review required"
            }
        }
    }

    let titleLine: String
    let branchLine: String
    let worktreeLine: String
    let statusIcon: StatusIcon
    /// Primary badge: the issue (when an issue tab) or the PR (PR-only tab).
    let trailingBadge: TrailingBadge
    /// PR linked to an issue tab, shown beneath the issue badge. `.none` unless
    /// the primary is an issue and a PR is linked.
    let secondaryBadge: TrailingBadge
    /// Owning repo `owner/name` shown above the branch. nil when grouping by
    /// repo is on (the section header already names the repo) or the repo is
    /// unknown.
    let repoLine: String?
    /// PR review decision dot, or nil when there's nothing to show.
    let reviewDot: ReviewDot?
    /// True when the tab was opened via the review picker (branch prefixed
    /// with `review-`). Drives the REVIEW pill in TabRow so the user can
    /// distinguish a review session from a normal one at a glance.
    let isReview: Bool
    /// A review tab whose PR gained commits/comments since the user last opened
    /// it — the "your move" state that turns the REVIEW pill amber.
    let reviewNeedsAttention: Bool
    /// Phase 6+: live status carrying the priority icon + tooltip lines + the
    /// unread-dot flag. nil when nothing has populated it yet.
    let liveStatus: TabStatus?

    /// `task == nil` for ad-hoc tabs that don't shadow a GitHub issue/PR.
    init(
        tab: YggdrasilTab,
        task: YggdrasilTask?,
        prTask: YggdrasilTask? = nil,
        liveStatus: TabStatus? = nil,
        repoName: String? = nil,
        grouped: Bool = false,
        maxWorktreeChars: Int = 50
    ) {
        if let task {
            titleLine = task.title
            switch task.type {
            case .pullRequest:
                trailingBadge = .prNumber(task.number)
            case .issue:
                trailingBadge = .issueNumber(task.number)
            }
        } else {
            titleLine = tab.branchName
            trailingBadge = .none
        }
        // The linked PR shows beneath the issue. Only meaningful when the
        // primary badge is an issue and the linked task is actually a PR.
        if case .issueNumber = trailingBadge,
           let prTask, prTask.type == .pullRequest {
            secondaryBadge = .prNumber(prTask.number)
        } else {
            secondaryBadge = .none
        }
        branchLine = tab.branchName
        worktreeLine = TabRowViewModel.midEllipsis(tab.worktreePath, max: maxWorktreeChars)
        self.liveStatus = liveStatus
        statusIcon = Self.mapIcon(liveStatus?.icon) ?? .idle
        isReview = NewTabSheet.isReviewBranch(tab.branchName)
        reviewNeedsAttention = NewTabSheet.isReviewBranch(tab.branchName)
            && (liveStatus?.reviewActivity ?? false)
        // Repo name is redundant with the section header when grouping by repo.
        repoLine = grouped ? nil : repoName
        reviewDot = ReviewDot(reviewState: liveStatus?.reviewState)
    }

    /// Map the aggregator's icon onto the row's enum. Returns nil to mean
    /// "use the default" so callers can fall back to .idle when liveStatus is nil.
    private static func mapIcon(_ icon: TabStatus.Icon?) -> StatusIcon? {
        switch icon {
        case .errored: .errored
        case .awaitingInput: .awaitingInput
        case .ciFailing: .ciFailing
        case .dirty: .dirty
        case .unread: .unread
        case .running: .running
        case .idle: .idle
        case .none: nil
        }
    }

    /// Mid-ellipsis truncation: keep the head and tail of `s`, drop the middle.
    /// `s.count <= max` returns `s` unchanged. Returns at minimum a single
    /// ellipsis when `max < 1`.
    static func midEllipsis(_ str: String, max: Int) -> String {
        if str.count <= max { return str }
        if max <= 1 { return "…" }
        let keep = max - 1 // 1 char for the ellipsis
        let headLen = keep - keep / 2
        let tailLen = keep / 2
        let head = str.prefix(headLen)
        let tail = str.suffix(tailLen)
        return "\(head)…\(tail)"
    }
}
