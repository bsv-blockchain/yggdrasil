import Foundation

/// Pure helpers behind "Link PR…": what the user typed → which PR, and which
/// repo a bare number refers to.
extension SidebarActions {
    /// Which PR "Link PR…" should import.
    struct LinkPRTarget: Equatable {
        let owner: String
        let name: String
        let number: Int

        var display: String {
            "\(owner)/\(name)#\(number)"
        }
    }

    /// Parse the "Link PR…" input. A PR URL or `owner/repo#N` names its repo;
    /// anything else (`123`, `#123`, `pr-123`) means PR N in the default repo.
    /// Issue URLs and junk return nil.
    static func parseLinkPRInput(_ raw: String, defaultOwner: String, defaultName: String) -> LinkPRTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        // owner/repo#N
        let hashParts = trimmed.split(separator: "#", omittingEmptySubsequences: false)
        if hashParts.count == 2 {
            let slug = hashParts[0].split(separator: "/", omittingEmptySubsequences: false)
            let digits = hashParts[1]
            if slug.count == 2,
               slug.allSatisfy({ !$0.isEmpty && !$0.contains(where: \.isWhitespace) }),
               !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits) {
                return LinkPRTarget(owner: String(slug[0]), name: String(slug[1]), number: number)
            }
        }

        let interpreted = NewTabSheet.interpretBranchInput(trimmed)
        if let slug = interpreted.repoSlug {
            // GitHub URL: only /pull/N is a PR.
            let ownerName = slug.split(separator: "/")
            guard interpreted.branch.hasPrefix("pr-"), ownerName.count == 2,
                  let number = Int(interpreted.branch.dropFirst(3)) else { return nil }
            return LinkPRTarget(owner: String(ownerName[0]), name: String(ownerName[1]), number: number)
        }
        guard let number = NewTabSheet.parsePRNumber(interpreted.branch) else { return nil }
        return LinkPRTarget(owner: defaultOwner, name: defaultName, number: number)
    }

    /// The repo a bare PR number in "Link PR…" refers to. Starts from the
    /// tab's task repo (an issue tab's issue repo), falling back to the repo
    /// owning the worktree path — two tracked repos can share one checkout,
    /// so the path alone can name the wrong one — then applies that repo's
    /// configured PR repo.
    static func defaultPRRepo(taskRepoID: Int64?, pathRepo: Repo, repos: [Repo]) -> Repo {
        let source = taskRepoID.flatMap { id in repos.first { $0.id == id } } ?? pathRepo
        return source.prRepo(among: repos)
    }

    /// The tracked repo `target` names. GitHub owner/repo names are
    /// case-insensitive, so a pasted URL may differ in case from what was
    /// typed when the repo was added.
    static func trackedRepo(for target: LinkPRTarget, in repos: [Repo]) -> Repo? {
        repos.first {
            $0.owner.caseInsensitiveCompare(target.owner) == .orderedSame
                && $0.name.caseInsensitiveCompare(target.name) == .orderedSame
        }
    }
}
