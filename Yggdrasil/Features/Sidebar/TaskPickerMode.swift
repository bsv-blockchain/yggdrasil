import Foundation

/// Mode toggle for the task-picker sheet. Same UI/flow, different source set:
/// `assigned` reads from `task` directly (sync filters to assignee:@me);
/// `review` reads from `pr_review_request` (PRs the user has been asked to
/// review, fetched via the search endpoint).
enum TaskPickerMode {
    case assigned
    case review

    var title: String {
        switch self {
        case .assigned: "Open Assigned"
        case .review: "PRs to Review"
        }
    }

    var emptyTitle: String {
        switch self {
        case .assigned: "Nothing to open"
        case .review: "No reviews waiting"
        }
    }

    var emptySubtitle: String {
        switch self {
        case .assigned: "All assigned issues and PRs are already open, or nothing has been synced yet."
        case .review: "You're not currently requested as a reviewer on any open PR."
        }
    }

    /// Branch + worktree name used when opening a task in this mode. The
    /// agent slug is the leading segment so the same PR can host parallel
    /// agents — each one ends up on its own branch in its own worktree
    /// directory (`<repoParent>/.worktrees/<agent>-<base>`). The `review-`
    /// infix still lets the sidebar and chrome pick up the REVIEW badge
    /// without a schema change.
    func branchName(for task: YggdrasilTask, agentName: String) -> String {
        let prefix = TaskPickerMode.agentSlug(agentName)
        let base: String = switch self {
        case .assigned:
            task.type == .pullRequest ? "pr-\(task.number)" : "issue-\(task.number)"
        case .review:
            "review-pr-\(task.number)"
        }
        return prefix.isEmpty ? base : "\(prefix)-\(base)"
    }

    /// Lowercase + hyphenated slug from an agent profile name. "Claude" →
    /// "claude"; "GitHub Copilot" → "github-copilot". Pure for testability.
    static func agentSlug(_ name: String) -> String {
        let lowered = name.lowercased()
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits)
        var out = ""
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            if allowed.contains(scalar) {
                out.append(Character(scalar))
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
