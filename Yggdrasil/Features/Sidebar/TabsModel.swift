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
    /// Cache: tabID → resolved agent identity (Claude/Codex/Gemini/Copilot/Grok).
    var agentByTabID: [Int64: AgentIdentity] = [:]
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
            tasksByTabID = try database.queue.read { db -> [Int64: YggdrasilTask] in
                var out: [Int64: YggdrasilTask] = [:]
                let allRepos = try Repo.fetchAll(db)
                for tab in self.tabs {
                    guard let tabID = tab.id else { continue }
                    if let taskID = tab.taskID,
                       let task = try YggdrasilTask.fetchOne(db, key: taskID) {
                        out[tabID] = task
                        continue
                    }
                    // Fallback: tab.taskID is nil (the user typed e.g. "pr-643"
                    // before sync had imported the task). Match by branch-name
                    // pattern + the repo whose localMainPath is an ancestor of
                    // the worktree. Lets the GitHub pane light up later as sync
                    // catches up, without needing the tab row touched.
                    if let task = try Self.lookupTaskByBranch(
                        branch: tab.branchName,
                        worktreePath: tab.worktreePath,
                        repos: allRepos,
                        db: db
                    ) {
                        out[tabID] = task
                    }
                }
                return out
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

    /// Lookup helper for the fallback path in `reload`. Returns the task whose
    /// `(repo_id, number)` matches a PR/issue-style branch name like "pr-643",
    /// scoped to the repo whose `localMainPath` is an ancestor of the
    /// worktree. Returns nil if either the branch doesn't look like a PR ref or
    /// no matching task has been synced yet.
    static func lookupTaskByBranch(
        branch: String,
        worktreePath: String,
        repos: [Repo],
        db: GRDB.Database
    ) throws -> YggdrasilTask? {
        guard let number = NewTabSheet.parsePRNumber(branch) else { return nil }
        // Match against the repo whose localMainPath is a directory prefix of
        // the worktree path. Worktree convention is <repoPath>/.worktrees/<slug>.
        let owningRepo = repos.first { repo in
            guard let path = repo.localMainPath, !path.isEmpty else { return false }
            let prefix = path.hasSuffix("/") ? path : path + "/"
            return worktreePath.hasPrefix(prefix)
        }
        guard let owningRepo, let repoID = owningRepo.id else { return nil }
        return try YggdrasilTask
            .filter(Column("repo_id") == repoID && Column("number") == number)
            .fetchOne(db)
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
