import Foundation

extension IssueDetailsPicker {
    /// Pure helper exposed for unit testing. The view body just renders the
    /// result, so all filter logic lives here in one place.
    static func filter(
        rows: [Row], search: String, trackedRepoKeys: Set<String>, trackedOnly: Bool
    ) -> [Row] {
        var result = rows
        if trackedOnly {
            result = result.filter { trackedRepoKeys.contains($0.repoFull) }
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return result }
        return result.filter { row in
            row.title.lowercased().contains(trimmed)
                || row.repoFull.lowercased().contains(trimmed)
                || "#\(row.number)".contains(trimmed)
                || row.labels.contains { $0.name.lowercased().contains(trimmed) }
                || row.milestone.lowercased().contains(trimmed)
        }
    }

    /// Local-DB-driven heuristic. We only know about PRs in tracked repos,
    /// so untracked-repo issues never get a linked PR — that's a known
    /// limitation, documented in the footer when the user selects one.
    static func linkedPR(
        forIssueNumber issueNumber: Int,
        repoKey: String,
        candidatePRs: [YggdrasilTask],
        repos: [String: Repo]
    ) -> YggdrasilTask? {
        guard let repoID = repos[repoKey]?.id else { return nil }
        let needle = "#\(issueNumber)"
        let pattern = try? NSRegularExpression(
            pattern: "(?<![0-9])\(NSRegularExpression.escapedPattern(for: needle))(?![0-9])"
        )
        return candidatePRs.first { pull in
            guard pull.repoID == repoID else { return false }
            let haystack = pull.title + " " + (pull.body ?? "")
            guard let pattern else { return haystack.contains(needle) }
            return pattern.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        }
    }
}
