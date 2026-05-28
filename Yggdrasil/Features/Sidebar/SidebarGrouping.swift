import Foundation

/// Pure helpers behind the "Group tabs by repository" sidebar preference.
/// Kept here (rather than inside `SidebarView`) so they can be unit-tested
/// without touching SwiftUI.
enum SidebarGrouping {
    enum GroupKey: Equatable {
        case repo(Repo)
        case other

        var title: String {
            switch self {
            case .repo(let repo): return repo.fullName
            case .other: return "Other"
            }
        }

        /// Stable identifier for SwiftUI `ForEach`.
        var id: String {
            switch self {
            case .repo(let repo): return "repo:\(repo.id.map(String.init) ?? repo.fullName)"
            case .other: return "other"
            }
        }
    }

    struct Group: Identifiable {
        let key: GroupKey
        let tabs: [YggdrasilTab]
        var id: String { key.id }
        var title: String { key.title }
    }

    /// Partition `tabs` into ordered groups by owning repo. Group order is
    /// the order each repo first appears in `tabs` — keeps grouping stable
    /// w.r.t. the user's manual tab ordering. Tabs whose repo can't be
    /// resolved are collected into a final `.other` group.
    static func groupByRepo(
        tabs: [YggdrasilTab],
        repoByTabID: [Int64: Repo]
    ) -> [Group] {
        var orderedKeys: [String] = []
        var bucket: [String: (GroupKey, [YggdrasilTab])] = [:]
        for tab in tabs {
            let key: GroupKey = tab.id.flatMap { repoByTabID[$0] }
                .map { GroupKey.repo($0) } ?? .other
            let id = key.id
            if var existing = bucket[id] {
                existing.1.append(tab)
                bucket[id] = existing
            } else {
                bucket[id] = (key, [tab])
                orderedKeys.append(id)
            }
        }
        return orderedKeys.compactMap { id in
            bucket[id].map { Group(key: $0.0, tabs: $0.1) }
        }
    }

    /// Whether a drag-reorder drop is allowed under the current grouping
    /// mode. When grouping is off, all drops are allowed. When grouping is
    /// on, source and target must belong to the same repo group (two
    /// `.other`-bucket tabs count as the same group).
    static func dropAllowed(
        sourceTabID: Int64,
        targetTabID: Int64,
        repoByTabID: [Int64: Repo],
        grouped: Bool
    ) -> Bool {
        guard grouped else { return true }
        let source = repoByTabID[sourceTabID]?.id
        let target = repoByTabID[targetTabID]?.id
        return source == target
    }
}
