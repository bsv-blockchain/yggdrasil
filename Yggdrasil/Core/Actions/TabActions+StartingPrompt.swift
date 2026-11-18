import Foundation
import GRDB

/// The prompt a new tab's Claude starts with: the caller's own, none, or the
/// user's template for the tab's PR or issue (`StartingPrompt`).
extension TabActions {
    /// What `choice` comes to. A template is skipped for an agent that
    /// isn't Claude, which can't take one; a prompt the caller wrote is
    /// refused for it instead, so it isn't silently dropped.
    static func startingPrompt(
        _ choice: StartingPrompt.Choice, for subject: StartingPrompt.Subject?,
        repo: Repo, agent: CodingAgent, services: AppServices
    ) throws -> String? {
        switch choice {
        case .none:
            return nil
        case let .custom(text):
            guard takesPrompt(agent) else { throw ActionError.promptNeedsClaude }
            return text
        case .template:
            guard let subject, takesPrompt(agent) else { return nil }
            return StartingPrompt.render(template(subject.kind, repo: repo, services: services), subject: subject)
        }
    }

    /// What the New Session sheet puts in its prompt field for `branchInput`,
    /// or "" for none. The user sees it there, so a PR the sync hasn't seen
    /// yet counts as one to review unless it's known to be theirs.
    static func suggestedPrompt(
        branchInput: String, repo: Repo, agent: CodingAgent, services: AppServices
    ) throws -> String {
        guard let subject = branchSubject(branchInput, repo: repo, lenient: true, services: services) else { return "" }
        return try startingPrompt(.template, for: subject, repo: repo, agent: agent, services: services) ?? ""
    }

    /// The PR or issue a typed branch names: `pr-N`, `issue-N`, `#N` or a
    /// GitHub URL. A PR is one to review when it's in Review Requests, or,
    /// when `lenient`, when it isn't one of the user's own.
    static func branchSubject(
        _ branchInput: String, repo: Repo, lenient: Bool, services: AppServices
    ) -> StartingPrompt.Subject? {
        let branch = NewTabSheet.interpretBranchInput(branchInput).branch
        guard let number = NewTabSheet.parsePRNumber(branch), let repoID = repo.id else { return nil }
        let isIssue = branch.lowercased().contains("issue")
        let synced = try? services.database.queue.read { db -> SyncedTask? in
            guard let task = try YggdrasilTask
                .filter(Column("repo_id") == repoID && Column("number") == number)
                .fetchOne(db), let taskID = task.id
            else { return nil }
            return try SyncedTask(
                task: task,
                requested: PRReviewRequest.fetchOne(db, key: taskID) != nil,
                mine: PRAuthored.fetchOne(db, key: taskID) != nil
            )
        }
        let found = synced ?? nil
        if isIssue {
            let url = found?.task.githubURL ?? "https://github.com/\(repo.fullName)/issues/\(number)"
            return .init(kind: .issue, number: number, url: url)
        }
        let isReview = if let found {
            found.task.type == .pullRequest && !found.mine && (found.requested || lenient)
        } else {
            lenient
        }
        guard isReview else { return nil }
        let url = found?.task.githubURL ?? "https://github.com/\(repo.fullName)/pull/\(number)"
        return .init(kind: .review, number: number, url: url)
    }

    /// A synced task, and whether the user was asked to review it or wrote it.
    private struct SyncedTask {
        let task: YggdrasilTask
        let requested: Bool
        let mine: Bool
    }

    private static func takesPrompt(_ agent: CodingAgent) -> Bool {
        AgentTerminalSurface.pinsClaudeSession(command: agent.command, args: agent.args)
    }

    /// Read fresh: the caller's copy of the repository can predate a change
    /// in Settings.
    private static func template(_ kind: StartingPrompt.Kind, repo: Repo, services: AppServices) -> String {
        let current = repo.id
            .flatMap { id in try? services.database.queue.read { db in try Repo.fetchOne(db, key: id) } }
        return StartingPrompt.template(
            kind,
            repoOverride: (current ?? repo).startingPrompt(kind),
            global: try? services.settingsStore.get(forKey: StartingPrompt.settingKey(kind))
        )
    }
}
