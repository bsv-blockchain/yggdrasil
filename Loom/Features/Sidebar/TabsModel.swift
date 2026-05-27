import Foundation
import Observation

/// View-model for the sidebar. Source of truth for the persistent list of tabs.
/// `LiveSessions` (was `SessionsModel`) tracks the in-memory agent runners
/// keyed by tab id.
@Observable
final class TabsModel {
    var tabs: [LoomTab] = []
    /// Cache: tabID → linked LoomTask (filled when a tab.taskID is non-nil).
    var tasksByTabID: [Int64: LoomTask] = [:]
    var selectedID: Int64?

    private let store: TabStore
    private let database: LoomDatabase

    init(store: TabStore, database: LoomDatabase) {
        self.store = store
        self.database = database
    }

    /// Reload from the DB. Cheap enough to call after any mutation.
    func reload() {
        do {
            tabs = try store.list()
            // Refresh the task index for tabs that shadow a GitHub task.
            tasksByTabID = try database.queue.read { db -> [Int64: LoomTask] in
                var out: [Int64: LoomTask] = [:]
                for tab in self.tabs {
                    guard let tabID = tab.id, let taskID = tab.taskID else { continue }
                    if let task = try LoomTask.fetchOne(db, key: taskID) {
                        out[tabID] = task
                    }
                }
                return out
            }
            // Drop selection if the row vanished.
            if let selected = selectedID, !tabs.contains(where: { $0.id == selected }) {
                selectedID = tabs.first?.id
            } else if selectedID == nil {
                selectedID = tabs.first?.id
            }
        } catch {
            LoomLog.ui.error("TabsModel.reload failed: \(String(describing: error), privacy: .public)")
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

    func model(for tab: LoomTab) -> TabRowViewModel {
        let task = tab.id.flatMap { tasksByTabID[$0] }
        return TabRowViewModel(tab: tab, task: task)
    }

    /// Phase 6+ overload: includes the live status so the row icon reflects
    /// the latest poller tick.
    func model(for tab: LoomTab, status: TabStatusModel) -> TabRowViewModel {
        let task = tab.id.flatMap { tasksByTabID[$0] }
        let live = tab.id.flatMap { status.status(forTabID: $0) }
        return TabRowViewModel(tab: tab, task: task, liveStatus: live)
    }

    /// Returns the tabs filtered by a case-insensitive substring match against the
    /// row's titleLine (task title or branch fallback) and branchName. Returns the
    /// full list when `query` is empty after trimming.
    func filtered(by query: String) -> [LoomTab] {
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
            LoomLog.ui.error("TabsModel.move failed: \(String(describing: error), privacy: .public)")
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
