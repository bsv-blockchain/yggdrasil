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
            let result = try resolveTaskAndRepoMaps()
            tasksByTabID = result.taskMap
            repoByTabID = result.repoMap
            for link in result.lazyLinks {
                try? store.setTaskID(id: link.tabID, taskID: link.taskID)
            }
            pendingReviewCount = try fetchPendingReviewCount()
            agentByTabID = try resolveAgentIdentities()
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

    /// Reads the task + repo lookups for the currently-loaded `tabs`. Also
    /// returns the set of (tabID, taskID) pairs whose `task_id` was nil
    /// but resolved via branch-name parsing — the caller persists those
    /// back to the DB so downstream `WHERE task_id IS NOT NULL` queries
    /// see them.
    private struct ResolveResult {
        let taskMap: [Int64: YggdrasilTask]
        let repoMap: [Int64: Repo]
        let lazyLinks: [(tabID: Int64, taskID: Int64)]
    }

    private func resolveTaskAndRepoMaps() throws -> ResolveResult {
        try database.queue.read { db -> ResolveResult in
            var tasks: [Int64: YggdrasilTask] = [:]
            var repos: [Int64: Repo] = [:]
            var lazyLinks: [(tabID: Int64, taskID: Int64)] = []
            let allRepos = try Repo.fetchAll(db)
            for tab in self.tabs {
                guard let tabID = tab.id else { continue }
                if let owning = Self.repoOwning(worktreePath: tab.worktreePath, repos: allRepos) {
                    repos[tabID] = owning
                }
                if let taskID = tab.taskID,
                   let task = try YggdrasilTask.fetchOne(db, key: taskID) {
                    tasks[tabID] = task
                    continue
                }
                // Lazy task link: branch-name matches an imported task row.
                if let owning = repos[tabID], let repoID = owning.id,
                   let number = NewTabSheet.parsePRNumber(tab.branchName),
                   let match = try YggdrasilTask
                   .filter(Column("repo_id") == repoID && Column("number") == number)
                   .fetchOne(db),
                   let matchID = match.id {
                    tasks[tabID] = match
                    lazyLinks.append((tabID: tabID, taskID: matchID))
                }
            }
            return ResolveResult(taskMap: tasks, repoMap: repos, lazyLinks: lazyLinks)
        }
    }

    private func fetchPendingReviewCount() throws -> Int {
        try database.queue.read { db in
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
    }

    /// Per-tab agent identity (claude/codex/gemini/copilot/grok) resolved
    /// from `CodingAgent.command` via the brand heuristic.
    private func resolveAgentIdentities() throws -> [Int64: AgentIdentity] {
        var out: [Int64: AgentIdentity] = [:]
        for tab in tabs {
            guard let tabID = tab.id else { continue }
            if let agentID = tab.codingAgentID,
               let agent = try agentStore.get(id: agentID) {
                out[tabID] = AgentIdentity.detect(command: agent.command)
            } else {
                out[tabID] = .claude
            }
        }
        return out
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

    func model(for tab: YggdrasilTab, grouped: Bool = false) -> TabRowViewModel {
        let task = tab.id.flatMap { tasksByTabID[$0] }
        return TabRowViewModel(tab: tab, task: task, repoName: repoName(for: tab), grouped: grouped)
    }

    /// Phase 6+ overload: includes the live status so the row icon reflects
    /// the latest poller tick.
    func model(for tab: YggdrasilTab, status: TabStatusModel, grouped: Bool = false) -> TabRowViewModel {
        let task = tab.id.flatMap { tasksByTabID[$0] }
        let live = tab.id.flatMap { status.status(forTabID: $0) }
        return TabRowViewModel(
            tab: tab, task: task, liveStatus: live,
            repoName: repoName(for: tab), grouped: grouped
        )
    }

    /// `owner/name` for the repo that owns this tab's worktree, or nil if not
    /// resolved (ad-hoc tab outside any tracked repo).
    func repoName(for tab: YggdrasilTab) -> String? {
        tab.id.flatMap { repoByTabID[$0] }?.fullName
    }

    /// Resolves the repo that owns a given worktree. Two layouts coexist:
    ///   • new (current): `<repo>/.worktrees/<slug>` — inside the repo
    ///   • legacy:        `<repo-parent>/.worktrees/<slug>` — sibling of repo
    /// We try in-repo first (path prefix match), then sibling-of-repo.
    static func repoOwning(worktreePath: String, repos: [Repo]) -> Repo? {
        // 1. In-repo: any tracked repo whose localMainPath is an ancestor of
        //    the worktree path. Most specific (longest) match wins so a
        //    nested workspace doesn't accidentally pick a parent repo.
        let insideCandidates = repos.compactMap { repo -> (Repo, Int)? in
            guard let path = repo.localMainPath, !path.isEmpty else { return nil }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return worktreePath.hasPrefix(prefix) ? (repo, prefix.count) : nil
        }
        if let inside = insideCandidates.max(by: { $0.1 < $1.1 })?.0 {
            return inside
        }

        // 2. Sibling-of-repo (legacy): grandparent of the worktree equals the
        //    repo's parent directory.
        let worktreeGrandparent = URL(fileURLWithPath: worktreePath, isDirectory: true)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .standardizedFileURL.path
        return repos.first { repo in
            guard let path = repo.localMainPath, !path.isEmpty else { return false }
            let repoParent = URL(fileURLWithPath: path, isDirectory: true)
                .deletingLastPathComponent()
                .standardizedFileURL.path
            return repoParent == worktreeGrandparent
        }
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
