import Foundation
import Observation

/// Per-tab status surface read by the sidebar `TabRow`. Populated by
/// `StatusPoller`. Defaults to a `.idle` placeholder when no entry yet — Phase 6
/// rolls real signals in incrementally.
@Observable
final class TabStatusModel {
    private var byTabID: [Int64: TabStatus] = [:]

    func status(forTabID tabID: Int64) -> TabStatus {
        byTabID[tabID] ?? TabStatus(
            icon: .idle, showsUnreadBadgeDot: false, tooltipLines: ["No status yet"]
        )
    }

    func set(_ status: TabStatus, forTabID tabID: Int64) {
        byTabID[tabID] = status
    }
}
