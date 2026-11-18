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
    /// GitHub URL. The prefix the number follows says which; a bare `#N` is
    /// whatever the sync has for it, else a PR. A PR is one to review as
    /// Review Requests defines it, or, when `lenient`, when it isn't known to
    /// be one of the user's own.
    static func branchSubject(
        _ branchInput: String, repo: Repo, lenient: Bool, services: AppServices
    ) -> StartingPrompt.Subject? {
        let branch = NewTabSheet.interpretBranchInput(branchInput).branch
        guard let number = NewTabSheet.parsePRNumber(branch), let repoID = repo.id else { return nil }
        let named = namedKind(branchInput: branchInput, branch: branch)
        // By type too: a fork's row holds its upstream's tasks, so issue #5
        // and PR #5 can both be there.
        let synced = (try? services.database.queue.read { db -> [SyncedTask] in
            try YggdrasilTask
                .filter(Column("repo_id") == repoID && Column("number") == number)
                .fetchAll(db)
                .compactMap { task in
                    guard let taskID = task.id else { return nil }
                    return try SyncedTask(
                        task: task,
                        toReview: TaskQueries.isToReview(db, taskID: taskID),
                        mine: PRAuthored.fetchOne(db, key: taskID) != nil
                    )
                }
        }) ?? []
        let issue = synced.first { $0.task.type == .issue }
        let pull = synced.first { $0.task.type == .pullRequest }
        let kind = named ?? (issue != nil && pull == nil ? .issue : .review)
        if kind == .issue {
            let url = issue?.task.githubURL ?? "https://github.com/\(repo.fullName)/issues/\(number)"
            return .init(kind: .issue, number: number, url: url)
        }
        let isReview = if let pull {
            pull.toReview || (lenient && !pull.mine)
        } else {
            lenient
        }
        guard isReview else { return nil }
        let url = pull?.task.githubURL ?? "https://github.com/\(repo.fullName)/pull/\(number)"
        return .init(kind: .review, number: number, url: url)
    }

    /// `.issue` or `.review` from the `issue`/`pr` prefix right before the
    /// number (so `fix-issue-pr-12` is a PR), or nil for a bare `#N` or `N`.
    private static func namedKind(branchInput: String, branch: String) -> StartingPrompt.Kind? {
        let input = branchInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.drop(while: { $0 == "#" }).allSatisfy(\.isNumber) { return nil }
        guard let match = branch.lowercased().firstMatch(of: #/(?:^|-)(?:review-)?(pr|issue)[-/]?\d+$/#) else {
            return nil
        }
        return match.1 == "issue" ? .issue : .review
    }

    /// A synced task, whether it's a PR to review, and whether the user wrote it.
    private struct SyncedTask {
        let task: YggdrasilTask
        let toReview: Bool
        let mine: Bool
    }

    /// Whether a synced task is a PR to review (`TaskQueries.isToReview`).
    static func isToReview(_ task: YggdrasilTask, services: AppServices) -> Bool {
        guard let id = task.id else { return false }
        return (try? services.database.queue.read { db in try TaskQueries.isToReview(db, taskID: id) }) ?? false
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
