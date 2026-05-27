import Foundation
import GRDB
import Observation

/// View-model for the sidebar. Source of truth for the persistent list of tabs.
/// `LiveSessions` (was `SessionsModel`) tracks the in-memory agent runners
/// keyed by tab id.
@Observable
final class TabsModel {
    var tabs: [YggdrasilTab] = []
    /// Cache: tabID → linked YggdrasilTask (filled when a tab.taskID is non-nil).
    var tasksByTabID: [Int64: YggdrasilTask] = [:]
    /// Cache: tabID → owning Repo, resolved from the tab's worktreePath. Lets
    /// the GitHub pane synthesize a URL for tabs whose PR/issue hasn't been
    /// synced yet (so we don't gate the WebView on the next 60s sync tick).
    var repoByTabID: [Int64: Repo] = [:]
    /// Cache: tabID → resolved agent identity (Claude/Codex/Gemini/Copilot/Grok).
    var agentByTabID: [Int64: AgentIdentity] = [:]
    /// Number of review-requested PRs not yet shadowed by a tab. Drives the
    /// "N to review" pill in the window chrome.
    var pendingReviewCount: Int = 0
    var selectedID: Int64?

    private let store: TabStore
    private let database: YggdrasilDatabase
    private let agentStore: CodingAgentStore

    init(store: TabStore, database: YggdrasilDatabase, agentStore: CodingAgentStore? = nil) {
        self.store = store
        self.database = database
        self.agentStore = agentStore ?? CodingAgentStore(database: database)
    }

    func agentIdentity(for tab: YggdrasilTab) -> AgentIdentity {
        if let id = tab.id, let cached = agentByTabID[id] { return cached }
        return .claude
    }

    /// Reload from the DB. Cheap enough to call after any mutation.
    func reload() {
        do {
            tabs = try store.list()
            // Refresh the task index for tabs that shadow a GitHub task.
            let (taskMap, repoMap) = try database.queue.read { db -> ([Int64: YggdrasilTask], [Int64: Repo]) in
                var tasks: [Int64: YggdrasilTask] = [:]
                var repos: [Int64: Repo] = [:]
                let allRepos = try Repo.fetchAll(db)
                for tab in self.tabs {
                    guard let tabID = tab.id else { continue }
                    // Always try to resolve the owning repo from the worktree
                    // path; the GitHub pane needs it as a fallback when no task
                    // row exists yet.
                    if let owning = Self.repoOwning(worktreePath: tab.worktreePath, repos: allRepos) {
                        repos[tabID] = owning
                    }
                    if let taskID = tab.taskID,
                       let task = try YggdrasilTask.fetchOne(db, key: taskID) {
                        tasks[tabID] = task
                        continue
                    }
                    // Lazy task link: tab.taskID is nil (the user typed e.g.
                    // "pr-643" before sync had imported the task). Match by
                    // branch-name pattern + owning repo. When the next sync
                    // brings the PR in, this lookup succeeds and the GitHub
                    // pane lights up — no tab row mutation required.
                    if let owning = repos[tabID], let repoID = owning.id,
                       let number = NewTabSheet.parsePRNumber(tab.branchName) {
                        let match = try YggdrasilTask
                            .filter(Column("repo_id") == repoID && Column("number") == number)
                            .fetchOne(db)
                        if let match {
                            tasks[tabID] = match
                        }
                    }
                }
                return (tasks, repos)
            }
            tasksByTabID = taskMap
            repoByTabID = repoMap
            pendingReviewCount = try database.queue.read { db in
                // Match AssignedTaskPicker(.review) — review-requested ∪
                // assigned-but-not-authored — minus what's already a tab.
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM task
                    WHERE task.type = 'pr'
                      AND (
                        task.id IN (SELECT task_id FROM pr_review_request)
                     OR (task.id IN (SELECT task_id FROM pr_assigned)
                         AND task.id NOT IN (SELECT task_id FROM pr_authored))
                      )
                      AND task.id NOT IN (SELECT task_id FROM tab WHERE task_id IS NOT NULL)
                    """) ?? 0
            }
            // Resolve per-tab agent identity from CodingAgent.command via the
            // brand heuristic (claude/codex/gemini/copilot/grok).
            agentByTabID = [:]
            for tab in tabs {
                guard let tabID = tab.id else { continue }
                if let agentID = tab.codingAgentID,
                   let agent = try agentStore.get(id: agentID) {
                    agentByTabID[tabID] = AgentIdentity.detect(command: agent.command)
                } else {
                    agentByTabID[tabID] = .claude
                }
            }
            // Drop selection if the row vanished.
            if let selected = selectedID, !tabs.contains(where: { $0.id == selected }) {
                selectedID = tabs.first?.id
            } else if selectedID == nil {
                selectedID = tabs.first?.id
            }
        } catch {
            YggdrasilLog.ui.error("TabsModel.reload failed: \(String(describing: error), privacy: .public)")
        }
    }

    func select(_ id: Int64) {
        selectedID = id
        try? store.touchLastActiveAt(id: id)
    }

    func moveSelection(by delta: Int) {
        guard !tabs.isEmpty else { return }
        let currentIdx = tabs.firstIndex(where: { $0.id == selectedID }) ?? 0
        let newIdx = (currentIdx + delta).clamped(to: 0 ... (tabs.count - 1))
        if let id = tabs[newIdx].id {
            select(id)
        }
    }

    func model(for tab: YggdrasilTab) -> TabRowViewModel {
        let task = tab.id.flatMap { tasksByTabID[$0] }
        return TabRowViewModel(tab: tab, task: task)
    }

    /// Phase 6+ overload: includes the live status so the row icon reflects
    /// the latest poller tick.
    func model(for tab: YggdrasilTab, status: TabStatusModel) -> TabRowViewModel {
        let task = tab.id.flatMap { tasksByTabID[$0] }
        let live = tab.id.flatMap { status.status(forTabID: $0) }
        return TabRowViewModel(tab: tab, task: task, liveStatus: live)
    }

    /// Resolves the repo that owns a given worktree. WorktreeManager creates
    /// worktrees at `<repoParent>/.worktrees/<slug>` — i.e. a sibling of the
    /// main checkout, not a child. So the owning repo is whichever tracked
    /// repo shares the worktree's grandparent directory.
    static func repoOwning(worktreePath: String, repos: [Repo]) -> Repo? {
        let worktreeURL = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let worktreeGrandparent = worktreeURL
            .deletingLastPathComponent()  // strip /<slug>
            .deletingLastPathComponent()  // strip /.worktrees
            .standardizedFileURL.path
        // Match the repo whose localMainPath sits inside that grandparent.
        let candidates = repos.compactMap { repo -> Repo? in
            guard let path = repo.localMainPath, !path.isEmpty else { return nil }
            let repoParent = URL(fileURLWithPath: path, isDirectory: true)
                .deletingLastPathComponent()
                .standardizedFileURL.path
            return repoParent == worktreeGrandparent ? repo : nil
        }
        if candidates.count == 1 { return candidates.first }
        // Multiple repos under the same parent dir — disambiguate by best path
        // prefix. The grandparent match got us one tier; here we accept any
        // repo whose own localMainPath happens to be an ancestor of the
        // worktree (would only happen if WorktreeManager later changes its
        // convention to live inside the repo).
        return repos.first { repo in
            guard let path = repo.localMainPath, !path.isEmpty else { return false }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return worktreePath.hasPrefix(prefix)
        } ?? candidates.first
    }

    /// Returns the tabs filtered by a case-insensitive substring match against the
    /// row's titleLine (task title or branch fallback) and branchName. Returns the
    /// full list when `query` is empty after trimming.
    func filtered(by query: String) -> [YggdrasilTab] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tabs }
        let needle = trimmed.lowercased()
        return tabs.filter { tab in
            let row = model(for: tab)
            return row.titleLine.lowercased().contains(needle)
                || row.branchLine.lowercased().contains(needle)
        }
    }

    /// SwiftUI `List`'s `.onMove(perform:)` shape. Reorders the in-memory array
    /// immediately for snappy UI and persists via `TabStore.reorder(ids:)`.
    func move(fromOffsets: IndexSet, toOffset: Int) {
        var reordered = tabs
        reordered.move(fromOffsets: fromOffsets, toOffset: toOffset)
        tabs = reordered

        let ids = reordered.compactMap(\.id)
        do {
            try store.reorder(ids: ids)
        } catch {
            YggdrasilLog.ui.error("TabsModel.move failed: \(String(describing: error), privacy: .public)")
            // Roll back: reload from disk to recover the canonical order.
            reload()
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
