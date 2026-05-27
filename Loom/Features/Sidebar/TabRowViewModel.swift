import Foundation

/// Pure view model for one sidebar row. Lives outside SwiftUI so the rendering
/// logic is unit-testable. Phase 6 will plumb `statusIcon` from `TabStatus`.
struct TabRowViewModel: Equatable {
    enum StatusIcon: Equatable {
        case idle
        case running
        case awaitingInput
        case errored
        case dirty
        case unread
        case ciFailing
    }

    enum TrailingBadge: Equatable {
        case none
        case prNumber(Int)
        case issueNumber(Int)
    }

    let titleLine: String
    let branchLine: String
    let worktreeLine: String
    let statusIcon: StatusIcon
    let trailingBadge: TrailingBadge
    /// Phase 6+: live status carrying the priority icon + tooltip lines + the
    /// unread-dot flag. nil when nothing has populated it yet.
    let liveStatus: TabStatus?

    /// `task == nil` for ad-hoc tabs that don't shadow a GitHub issue/PR.
    init(
        tab: LoomTab,
        task: LoomTask?,
        liveStatus: TabStatus? = nil,
        maxWorktreeChars: Int = 50
    ) {
        if let task {
            titleLine = task.title
            switch task.type {
            case .pullRequest:
                trailingBadge = .prNumber(task.number)
            case .issue:
                trailingBadge = .issueNumber(task.number)
            }
        } else {
            titleLine = tab.branchName
            trailingBadge = .none
        }
        branchLine = tab.branchName
        worktreeLine = TabRowViewModel.midEllipsis(tab.worktreePath, max: maxWorktreeChars)
        self.liveStatus = liveStatus
        statusIcon = Self.mapIcon(liveStatus?.icon) ?? .idle
    }

    /// Map the aggregator's icon onto the row's enum. Returns nil to mean
    /// "use the default" so callers can fall back to .idle when liveStatus is nil.
    private static func mapIcon(_ icon: TabStatus.Icon?) -> StatusIcon? {
        switch icon {
        case .errored: .errored
        case .awaitingInput: .awaitingInput
        case .ciFailing: .ciFailing
        case .dirty: .dirty
        case .unread: .unread
        case .running: .running
        case .idle: .idle
        case .none: nil
        }
    }

    /// Mid-ellipsis truncation: keep the head and tail of `s`, drop the middle.
    /// `s.count <= max` returns `s` unchanged. Returns at minimum a single
    /// ellipsis when `max < 1`.
    static func midEllipsis(_ str: String, max: Int) -> String {
        if str.count <= max { return str }
        if max <= 1 { return "…" }
        let keep = max - 1 // 1 char for the ellipsis
        let headLen = keep - keep / 2
        let tailLen = keep / 2
        let head = str.prefix(headLen)
        let tail = str.suffix(tailLen)
        return "\(head)…\(tail)"
    }
}
