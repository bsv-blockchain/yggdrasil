import Foundation
import GRDB

/// Linking a tab to a pull request, as Link PR… and Unlink PR do.
extension TabActions {
    /// The repo a bare PR number refers to for this tab: its task's repo (an
    /// issue tab's issue repo), else the repo its worktree is in, then that
    /// repo's configured PR repo.
    static func defaultPRRepo(tabID: Int64, services: AppServices) throws -> Repo {
        _ = try tab(tabID, services)
        guard let pathRepo = services.tabs.repoByTabID[tabID] else { throw ActionError.notInTrackedRepo }
        let repos = try services.database.queue.read { db in try Repo.fetchAll(db) }
        return SidebarActions.defaultPRRepo(
            taskRepoID: services.tabs.tasksByTabID[tabID]?.repoID, pathRepo: pathRepo, repos: repos
        )
    }

    /// The open PR whose head is the tab's branch, in its PR repo; nil when
    /// there's none or GitHub can't be asked.
    static func suggestedPRNumber(tabID: Int64, services: AppServices) async -> Int? {
        guard let tab = try? tab(tabID, services), let repo = try? defaultPRRepo(tabID: tabID, services: services)
        else { return nil }
        return try? await services.syncService.linkablePRNumber(
            forBranch: tab.branchName, owner: repo.owner, name: repo.name
        )
    }

    /// Which PR `input` names for this tab: a number (`12`, `#12`, `pr-12`)
    /// in its PR repo, or a PR URL or `owner/repo#N` in any tracked repo.
    static func resolvePR(
        _ input: String, tabID: Int64, services: AppServices
    ) throws -> (target: SidebarActions.LinkPRTarget, repo: Repo) {
        let prRepo = try defaultPRRepo(tabID: tabID, services: services)
        guard let target = SidebarActions.parseLinkPRInput(
            input, defaultOwner: prRepo.owner, defaultName: prRepo.name
        ) else { throw ActionError.invalidArgument("pr") }
        let repos = try services.database.queue.read { db in try Repo.fetchAll(db) }
        guard let repo = SidebarActions.trackedRepo(for: target, in: repos) else {
            throw ActionError.repoNotTracked("\(target.owner)/\(target.name)")
        }
        return (target, repo)
    }

    /// Links the PR `input` names (see `resolvePR`) and returns it as
    /// `owner/repo#N`.
    @discardableResult
    static func linkPR(tabID: Int64, pr input: String, services: AppServices) async throws -> String {
        let resolved = try resolvePR(input, tabID: tabID, services: services)
        try await linkPR(tabID: tabID, repo: resolved.repo, number: resolved.target.number, services: services)
        return resolved.target.display
    }

    /// Links PR `number` of `repo`. On an issue tab the PR goes next to the
    /// issue; otherwise it becomes the tab's task.
    static func linkPR(tabID: Int64, repo: Repo, number: Int, services: AppServices) async throws {
        _ = try tab(tabID, services)
        let taskID = try await services.syncService.importPR(owner: repo.owner, name: repo.name, number: number)
        if services.tabs.tasksByTabID[tabID]?.type == .issue {
            try services.tabStore.setPRTaskID(id: tabID, prTaskID: taskID)
        } else {
            try services.tabStore.setTaskID(id: tabID, taskID: taskID)
        }
        services.tabs.reload()
        services.triggerSyncNow()
    }

    /// Drops an issue tab's linked PR, keeping the issue; on any other tab
    /// drops its task, leaving a plain terminal tab.
    static func unlinkPR(tabID: Int64, services: AppServices) throws {
        // The stored row, not the sidebar's copy: that one lags a link made
        // since its last reload.
        guard let tab = try services.tabStore.get(id: tabID), tab.kind == .tab else {
            throw ActionError.unknownTab(tabID)
        }
        if tab.prTaskID != nil {
            try services.tabStore.setPRTaskID(id: tabID, prTaskID: nil)
        } else {
            try services.tabStore.setTaskID(id: tabID, taskID: nil)
        }
        services.tabs.reload()
    }
}
