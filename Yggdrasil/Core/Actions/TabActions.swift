import Foundation

/// Everything a user can do to a tab, without the dialogs around it. The
/// sidebar, menus and pickers ask their questions, then call these; nothing
/// here shows UI, so any caller gets the same behaviour.
@MainActor
enum TabActions {
    // MARK: - Open

    /// The branch a tab gets for what was typed, where its worktree starts
    /// from, and the repo a pasted GitHub URL points at.
    struct BranchPlan: Equatable {
        let branch: String
        let baseRef: String?
        let repoSlug: String?
    }

    /// `pr-N` / `issue-N` (or a GitHub URL or `#N` for one) keep their name, so
    /// the branch matches the PR and a later `git push` reaches it; a PR starts
    /// from its head. Anything else gets the agent's prefix, so several agents
    /// can work the same idea side by side, and starts from `baseBranch`.
    static func plan(branchInput: String, agentName: String, baseBranch: String?) -> BranchPlan {
        let interpretation = NewTabSheet.interpretBranchInput(branchInput)
        let userBranch = interpretation.branch
        let number = NewTabSheet.parsePRNumber(userBranch)
        let agentSlug = TaskPickerMode.agentSlug(agentName)
        let branch: String = if number != nil || agentSlug.isEmpty
            || userBranch.lowercased().hasPrefix(agentSlug.lowercased() + "-") {
            userBranch
        } else {
            "\(agentSlug)-\(userBranch)"
        }
        let base = baseBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prHead = number.flatMap { number in
            userBranch.lowercased().hasPrefix("pr-") ? "refs/pull/\(number)/head" : nil
        }
        return BranchPlan(
            branch: branch,
            baseRef: prHead ?? (base.isEmpty ? nil : base),
            repoSlug: interpretation.repoSlug
        )
    }

    struct OpenRequest {
        var repo: Repo
        var branchInput: String
        var baseBranch: String?
        /// nil = this Mac.
        var host: RemoteHost?
        var agent: CodingAgent
        var select = true
        /// What a new Claude conversation starts with.
        var prompt: String?
    }

    /// The New Session sheet's Start. The worktree is built in the background,
    /// so this returns as soon as the tab exists. On this Mac the repo must be
    /// cloned already; on a host it's cloned with the worktree.
    static func open(_ request: OpenRequest, services: AppServices) async throws -> Int64 {
        let repo = request.repo
        try checkPrompt(request.prompt, agent: request.agent)
        let plan = plan(branchInput: request.branchInput, agentName: request.agent.name, baseBranch: request.baseBranch)
        guard request.host != nil || repo.localMainPath != nil,
              let path = try services.plannedWorktreePath(repo: repo, branch: plan.branch, host: request.host)
        else { throw ActionError.repoNotCloned(repo.fullName) }
        // Links "pr-643" & co. to their task, when the sync has it.
        let taskID = repo.id.flatMap {
            NewTabSheet.resolveTaskID(forBranch: plan.branch, repoID: $0, database: services.database)
        }
        return try await insertAndPrepare(
            branch: plan.branch, path: path, taskID: taskID, baseRef: plan.baseRef,
            repo: repo, host: request.host, agent: request.agent, select: request.select,
            prompt: request.prompt, services: services
        )
    }

    private static func checkPrompt(_ prompt: String?, agent: CodingAgent) throws {
        guard prompt != nil else { return }
        guard AgentTerminalSurface.pinsClaudeSession(command: agent.command, args: agent.args) else {
            throw ActionError.promptNeedsClaude
        }
    }

    // The open paths take what the New Session sheet and pickers collect.
    // swiftlint:disable function_parameter_count
    /// Opens a row of Assigned Tasks or Review Requests, linked to its task.
    static func openTask(
        _ task: YggdrasilTask, repo: Repo, mode: TaskPickerMode, host: RemoteHost?, agent: CodingAgent,
        select: Bool = true, prompt: String? = nil, services: AppServices
    ) async throws -> Int64 {
        try checkPrompt(prompt, agent: agent)
        let branch = mode.branchName(for: task, agentName: agent.name)
        guard host != nil || repo.localMainPath != nil,
              let path = try services.plannedWorktreePath(repo: repo, branch: branch, host: host)
        else { throw ActionError.repoNotCloned(repo.fullName) }
        // The row may have been pruned since it was listed (closing a tab
        // unprotects its task, and the sync on close deletes it): look it up
        // again, or the insert fails the foreign key.
        let taskID = try await services.database.queue.write { db in
            try TaskSyncWrites.resolveOrReviveTask(db: db, snapshot: task)
        }
        return try await insertAndPrepare(
            branch: branch, path: path, taskID: taskID,
            baseRef: task.type == .pullRequest ? "refs/pull/\(task.number)/head" : nil,
            repo: repo, host: host, agent: agent, select: select, prompt: prompt, services: services
        )
    }

    /// Opens an issue from My Issues. Those come straight from GitHub and may
    /// not be synced, so the tab isn't linked to a task.
    static func openIssue(
        number: Int, title: String, url: String, repo: Repo, host: RemoteHost?, agent: CodingAgent,
        select: Bool = true, services: AppServices
    ) async throws -> Int64 {
        let issue = YggdrasilTask(
            id: nil, repoID: repo.id ?? 0, type: .issue, number: number,
            title: title, body: nil, state: .open, authorLogin: "",
            githubURL: url, apiURL: url,
            createdAt: Date(), updatedAt: Date(), lastSyncedAt: Date(),
            etag: nil, labelsJSON: "[]", milestoneTitle: nil
        )
        let branch = TaskPickerMode.assigned.branchName(for: issue, agentName: agent.name)
        guard host != nil || repo.localMainPath != nil,
              let path = try services.plannedWorktreePath(repo: repo, branch: branch, host: host)
        else { throw ActionError.repoNotCloned(repo.fullName) }
        return try await insertAndPrepare(
            branch: branch, path: path, taskID: nil, baseRef: nil,
            repo: repo, host: host, agent: agent, select: select, services: services
        )
    }

    /// Coding ▸ New Session: an agent in any folder, with no worktree or branch.
    @discardableResult
    static func openAdHoc(path: String, agent: CodingAgent, select: Bool = true,
                          services: AppServices) throws -> Int64 {
        let tab = try services.tabStore.insert(branchName: "ad-hoc", worktreePath: path, agentID: agent.id, taskID: nil)
        services.tabs.reload()
        guard let tabID = tab.id else { throw ActionError.unknownTab(0) }
        if select { services.tabs.select(tabID) }
        services.sessions.add(OpenSession(
            id: tabID,
            displayName: "\(agent.name) · \(URL(fileURLWithPath: path).lastPathComponent)",
            cwd: path,
            command: agent.command,
            args: agent.args,
            env: agent.env
        ))
        return tabID
    }

    private static func insertAndPrepare(
        branch: String, path: String, taskID: Int64?, baseRef: String?,
        repo: Repo, host: RemoteHost?, agent: CodingAgent, select: Bool, prompt: String? = nil,
        services: AppServices
    ) async throws -> Int64 {
        let tab = try services.tabStore.insert(
            branchName: branch, worktreePath: path, agentID: agent.id, taskID: taskID,
            preparationState: .pending, hostID: host?.id
        )
        services.tabs.reload()
        guard let tabID = tab.id else { throw ActionError.unknownTab(0) }
        if let prompt { services.sessions.setPrompt(prompt, tabID: tabID) }
        if select { services.tabs.select(tabID) }
        await services.worktreePreparer.enqueue(tabID: tabID, repo: repo, host: host, branch: branch, baseRef: baseRef)
        services.triggerSyncNow()
        return tabID
    }

    // swiftlint:enable function_parameter_count

    // MARK: - Select

    /// Selects the tab in the sidebar and shows it in the main pane.
    static func select(tabID: Int64, services: AppServices) throws {
        _ = try tab(tabID, services)
        services.tabs.select(tabID)
        services.sessions.selectedID = tabID
    }

    // MARK: - Close

    /// Closes the tab, stopping its agent, and with `deleteWorktree` runs
    /// `git worktree remove --force` on it (on its host for a remote tab).
    /// The tab is gone when this returns; what couldn't be cleaned up on the
    /// way is returned for the caller to show.
    static func close(
        id: Int64, deleteWorktree: Bool, services: AppServices, defaults: UserDefaults = .standard
    ) async throws -> [String] {
        let tab = try tab(id, services)
        let host = services.host(for: tab)
        let repo = services.tabs.repoByTabID[id]
        removeRecord(id: id, services: services, defaults: defaults)

        var problems: [String] = []
        if let host {
            // `removeRecord` only detached a remote agent.
            do {
                try await services.remoteControl.kill(host: host, tabID: id)
            } catch {
                problems.append("The agent couldn't be stopped: \(error)")
            }
        }
        // Independent of the kill: a dead agent is no reason to leave the
        // worktree behind for the next tab on this branch to pick up.
        guard deleteWorktree else { return problems }
        guard let repo else {
            problems.append("The worktree isn't under a tracked repository's checkout, so it was left in place.")
            return problems
        }
        do {
            let manager = try host.map { try services.existingWorktreeManager(on: $0, repo: repo) }
                ?? services.worktreeManager
            try await manager.remove(
                repo: repo,
                path: URL(fileURLWithPath: tab.worktreePath, isDirectory: true),
                force: true
            )
            YggdrasilLog.ui
                .info("Removed worktree \(tab.worktreePath, privacy: .public) for tab \(id, privacy: .public)")
        } catch {
            problems.append("The worktree couldn't be removed: \(error)")
        }
        return problems
    }

    private static func removeRecord(id: Int64, services: AppServices, defaults: UserDefaults) {
        // Tear down the running agent first so its files aren't held open by
        // the time `git worktree remove` runs. (Dismantling its surface stops
        // and collects the process; a remote one is only detached.)
        services.sessions.remove(id: id)
        services.sessions.forgetOpened(tabID: id)

        // Optimistic dismissal: if this tab's task was in pr_review_request
        // (a "PR to review" the user just finished with), drop the membership
        // locally BEFORE we reload. Without this the count briefly bounces
        // back up until the next sync learns the review was submitted. That
        // sync restores the row in the rare case the user closed without
        // actually reviewing.
        if let taskID = services.tabs.tasksByTabID[id]?.id {
            try? services.database.queue.write { db in
                try db.execute(sql: "DELETE FROM pr_review_request WHERE task_id = ?", arguments: [taskID])
            }
        }

        // Drop the mute with the tab; a key left behind would silently muffle
        // a future tab that reused the id.
        AttentionDismissal.restore(tabID: id, defaults: defaults)
        // Call off any queued preparation: otherwise closing a tab you just
        // opened still creates the worktree and branch afterwards, with
        // nothing referencing them — and for "Remove Tab + Worktree" it
        // recreates exactly what the user asked to delete.
        Task { await services.worktreePreparer.cancel(tabID: id) }

        do {
            try services.tabStore.delete(id: id)
        } catch {
            YggdrasilLog.ui
                .error("Failed to delete tab \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        services.tabs.reload()
        // GitHub-side state (pr_review_request, CI status) may have changed
        // while this tab was open: sync now so the review pill and per-tab
        // status catch up instead of waiting for the next scheduled tick.
        services.triggerSyncNow()
    }

    // MARK: - Attention

    /// Mutes the tab's amber until something actually changes: a new commit,
    /// thread, review request or agent record changes its fingerprint.
    static func mute(tabID: Int64, services: AppServices, defaults: UserDefaults = .standard) throws {
        _ = try tab(tabID, services)
        let signature = services.tabStatus.status(forTabID: tabID).attentionSignature
        // Before the first poll tick a tab has only the placeholder status,
        // whose signature is empty. Storing that would be a silent no-op: the
        // next tick overwrites it and the mute lapses with nothing visible.
        guard !signature.isEmpty else { throw ActionError.noStatusYet }
        AttentionDismissal.dismiss(tabID: tabID, signature: signature, defaults: defaults)
        services.tabs.reload()
    }

    static func unmute(tabID: Int64, services: AppServices, defaults: UserDefaults = .standard) throws {
        _ = try tab(tabID, services)
        AttentionDismissal.restore(tabID: tabID, defaults: defaults)
        services.tabs.reload()
    }

    // MARK: - Setup, links, order

    /// Runs a failed worktree preparation again.
    static func retrySetup(tabID: Int64, services: AppServices) throws {
        let tab = try tab(tabID, services)
        guard let repo = services.tabs.repoByTabID[tabID] else { throw ActionError.notInTrackedRepo }
        // A move stops and starts the agent itself; a retry would race it.
        guard !services.sessions.movingTabs.contains(tabID) else { throw ActionError.moveInProgress }
        let baseRef: String? = services.tabs.tasksByTabID[tabID].flatMap { task in
            task.type == .pullRequest ? "refs/pull/\(task.number)/head" : nil
        }
        try? services.tabStore.setPreparation(id: tabID, state: .pending, error: nil)
        services.tabs.reload()
        let host = services.host(for: tab)
        Task {
            await services.worktreePreparer.enqueue(
                tabID: tabID, repo: repo, host: host, branch: tab.branchName, baseRef: baseRef
            )
        }
    }

    /// Moves the tab to `index` in the sidebar order (clamped to the ends).
    static func reorder(tabID: Int64, to index: Int, services: AppServices) throws {
        _ = try tab(tabID, services)
        guard let from = services.tabs.tabs.firstIndex(where: { $0.id == tabID }) else {
            throw ActionError.unknownTab(tabID)
        }
        let target = min(max(index, 0), services.tabs.tabs.count - 1)
        guard target != from else { return }
        // `move(fromOffsets:toOffset:)` counts the destination before removal.
        services.tabs.move(fromOffsets: IndexSet(integer: from), toOffset: target > from ? target + 1 : target)
    }

    // MARK: - Panes

    /// Sets the tab's panes: `agent`, `github`, `diff`, `agent+diff`,
    /// `agent+github` or `diff+github`. A mounted tab switches at once.
    static func setLayout(
        tabID: Int64, layout raw: String, services: AppServices, defaults: UserDefaults = .standard
    ) throws {
        guard let layout = PaneLayout(rawValue: raw) else { throw ActionError.invalidArgument("layout") }
        let tab = try tab(tabID, services)
        layout.persist(for: tab, defaults: defaults)
        try services.tabStore.setLastMainView(id: tabID, view: layout.primarySegment.tabMainView)
        NotificationCenter.default.post(name: PaneLayout.changedNotification, object: tabID)
    }

    /// Sets what the Diff pane compares: `branch` (the branch and uncommitted
    /// work) or `uncommitted`.
    static func setDiffScope(
        tabID: Int64, scope raw: String, services: AppServices, defaults: UserDefaults = .standard
    ) throws {
        guard let scope = DiffSubPane.Coordinator.parseScope(raw) else { throw ActionError.invalidArgument("scope") }
        let tab = try tab(tabID, services)
        DiffSubPane.Coordinator.persistScope(scope, for: tab, defaults: defaults)
        NotificationCenter.default.post(name: DiffSubPane.scopeChangedNotification, object: tabID)
    }

    static func reloadGitHub(tabID: Int64, services: AppServices) throws {
        _ = try tab(tabID, services)
        NotificationCenter.default.post(name: MainPaneView.reloadGitHubNotification, object: tabID)
    }

    // MARK: -

    static func tab(_ id: Int64, _ services: AppServices) throws -> YggdrasilTab {
        guard let tab = services.tabs.tabs.first(where: { $0.id == id }) else { throw ActionError.unknownTab(id) }
        return tab
    }
}
