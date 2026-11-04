import Foundation
import Observation

/// Each tab's unfinished subagents, filled in by `StatusPoller`, and the one
/// whose transcript the main pane shows.
@Observable
final class SubagentsModel {
    struct Selection: Equatable {
        let tabID: Int64
        /// Kept as it was when chosen: the view stays open, marked finished,
        /// after the subagent drops out of the list.
        let info: SubagentInfo
    }

    private var byTabID: [Int64: [SubagentInfo]] = [:]
    private(set) var selected: Selection?

    /// Writes only on a real change: the sidebar redraws on every write, and
    /// this is called for every tab every few seconds.
    func set(_ subagents: [SubagentInfo], forTabID tabID: Int64) {
        guard (byTabID[tabID] ?? []) != subagents else { return }
        byTabID[tabID] = subagents.isEmpty ? nil : subagents
    }

    /// The tab's subagents that are still working. A meta file says
    /// "unfinished" forever when its `claude` was killed, so they only count
    /// while the tab's agent runs.
    func running(forTabID tabID: Int64, parentRunning: Bool) -> [SubagentInfo] {
        // Read before the check, always: a view that drew while the agent
        // wasn't up yet still has to hear when subagents arrive.
        let listed = byTabID[tabID] ?? []
        return parentRunning ? listed : []
    }

    func isRunning(agentID: String, tabID: Int64) -> Bool {
        byTabID[tabID]?.contains { $0.agentID == agentID } ?? false
    }

    func select(_ info: SubagentInfo, tabID: Int64) {
        selected = Selection(tabID: tabID, info: info)
    }

    func selection(forTabID tabID: Int64) -> Selection? {
        selected?.tabID == tabID ? selected : nil
    }

    func clearSelection() {
        selected = nil
    }

    /// Drops what belongs to tabs that are gone.
    func retain(tabIDs: Set<Int64>) {
        if byTabID.keys.contains(where: { !tabIDs.contains($0) }) {
            byTabID = byTabID.filter { tabIDs.contains($0.key) }
        }
        if let selected, !tabIDs.contains(selected.tabID) { self.selected = nil }
    }
}
