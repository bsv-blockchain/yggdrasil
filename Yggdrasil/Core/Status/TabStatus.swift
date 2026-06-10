import Foundation

/// Slim view of the GitHub status row (Phase 1's `github_status` table). Used
/// by the status aggregator so it doesn't have to know how the row was
/// fetched.
struct GitHubAggregate: Equatable {
    let ciState: String? // e.g. "SUCCESS", "FAILURE", "PENDING", or nil
    /// GitHub's `reviewDecision`: "APPROVED", "CHANGES_REQUESTED",
    /// "REVIEW_REQUIRED", or nil for non-PR tabs / PRs with no review activity.
    let reviewState: String?
    let unread: Int // unread comments + reviews since last_seen_comment_id

    init(ciState: String?, reviewState: String? = nil, unread: Int) {
        self.ciState = ciState
        self.reviewState = reviewState
        self.unread = unread
    }
}

/// The combined sidebar-row status. `icon` is the highest-priority signal per
/// the spec's order: errored > awaiting_input > CI failing > dirty > unread >
/// running > idle. `showsUnreadBadgeDot` controls the coloured dot on the
/// trailing badge regardless of which icon is shown.
struct TabStatus: Equatable {
    enum Icon: String, Equatable {
        case errored, awaitingInput, ciFailing, dirty, unread, running, idle
    }

    let icon: Icon
    let showsUnreadBadgeDot: Bool
    let tooltipLines: [String]
    /// Raw GitHub review decision for the linked PR (or nil). Surfaced as a
    /// coloured dot on the row; deliberately independent of `icon` so it never
    /// displaces the work-state icon.
    let reviewState: String?

    init(icon: Icon, showsUnreadBadgeDot: Bool, tooltipLines: [String], reviewState: String? = nil) {
        self.icon = icon
        self.showsUnreadBadgeDot = showsUnreadBadgeDot
        self.tooltipLines = tooltipLines
        self.reviewState = reviewState
    }

    static func aggregate(
        claude: ClaudeState,
        git: GitState,
        github: GitHubAggregate
    ) -> TabStatus {
        let icon = pickIcon(claude: claude, git: git, github: github)
        return TabStatus(
            icon: icon,
            showsUnreadBadgeDot: github.unread > 0,
            tooltipLines: makeTooltip(claude: claude, git: git, github: github),
            reviewState: github.reviewState
        )
    }

    private static func pickIcon(
        claude: ClaudeState, git: GitState, github: GitHubAggregate
    ) -> Icon {
        if claude == .errored { return .errored }
        if claude == .awaitingInput { return .awaitingInput }
        if github.ciState == "FAILURE" || github.ciState == "FAILED"
            || github.ciState == "ERROR" { return .ciFailing }
        if git.dirty { return .dirty }
        if github.unread > 0 { return .unread }
        if claude == .running { return .running }
        return .idle
    }

    private static func makeTooltip(
        claude: ClaudeState, git: GitState, github: GitHubAggregate
    ) -> [String] {
        var lines: [String] = []
        lines.append("Claude: \(claudeDescription(claude))")
        lines.append(gitDescription(git))
        if case let .ahead(ahead, behind) = git.remote, (ahead + behind) > 0 {
            lines.append("\(ahead) ahead, \(behind) behind upstream")
        }
        if let ciState = github.ciState { lines.append("CI: \(ciState)") }
        if let review = reviewLabel(github.reviewState) { lines.append("Review: \(review)") }
        if github.unread > 0 { lines.append("\(github.unread) unread comment(s)") }
        return lines
    }

    /// GitHub-worded label for a `reviewDecision`, or nil for states we don't
    /// surface (no review activity / draft).
    static func reviewLabel(_ reviewState: String?) -> String? {
        switch reviewState?.uppercased() {
        case "APPROVED": "Approved"
        case "CHANGES_REQUESTED": "Changes requested"
        case "REVIEW_REQUIRED": "Review required"
        default: nil
        }
    }

    private static func claudeDescription(_ state: ClaudeState) -> String {
        switch state {
        case .unknown: "unknown"
        case .running: "running"
        case .awaitingInput: "awaiting input"
        case .idle: "idle"
        case .errored: "errored"
        }
    }

    private static func gitDescription(_ git: GitState) -> String {
        git.dirty ? "git: dirty" : "git: clean"
    }
}
