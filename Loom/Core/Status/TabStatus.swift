import Foundation

/// Slim view of the GitHub status row (Phase 1's `github_status` table). Used
/// by the status aggregator so it doesn't have to know how the row was
/// fetched.
struct GitHubAggregate: Equatable {
    let ciState: String?     // e.g. "SUCCESS", "FAILURE", "PENDING", or nil
    let unread: Int          // unread comments + reviews since last_seen_comment_id
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

    static func aggregate(
        claude: ClaudeState,
        git: GitState,
        github: GitHubAggregate
    ) -> TabStatus {
        let icon = pickIcon(claude: claude, git: git, github: github)
        return TabStatus(
            icon: icon,
            showsUnreadBadgeDot: github.unread > 0,
            tooltipLines: makeTooltip(claude: claude, git: git, github: github)
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
        if github.unread > 0 { lines.append("\(github.unread) unread comment(s)") }
        return lines
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
