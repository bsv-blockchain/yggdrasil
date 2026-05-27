import Foundation

/// Status of a worktree's git tree + relationship to upstream.
struct GitState: Equatable {
    enum RemoteState: Equatable {
        case noRemote
        case ahead(Int, behind: Int)
    }

    let dirty: Bool
    let remote: RemoteState
}

/// Runs `git status --porcelain` + `git rev-list --left-right --count` and
/// parses the output into a `GitState`. Pure parsing helpers are static so
/// they can be unit-tested without spawning git.
struct GitStateProbe {
    let git: GitRunner

    init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    func probe(worktreePath: String) async throws -> GitState {
        let cwd = URL(fileURLWithPath: worktreePath, isDirectory: true)

        let porcelain = try await git.run(args: ["status", "--porcelain"], cwd: cwd)
        let dirty = Self.parseDirty(porcelain: porcelain.stdout)

        // The rev-list invocation throws when there's no upstream — interpret that
        // as `.noRemote` rather than a hard error.
        do {
            let result = try await git.run(
                args: ["rev-list", "--left-right", "--count", "HEAD...@{upstream}"],
                cwd: cwd
            )
            if let parsed = Self.parseAheadBehind(result.stdout) {
                return GitState(
                    dirty: dirty,
                    remote: .ahead(parsed.ahead, behind: parsed.behind)
                )
            }
        } catch {
            // fall through to .noRemote
        }
        return GitState(dirty: dirty, remote: .noRemote)
    }

    // MARK: - Parsing (pure)

    /// Any non-whitespace content in porcelain output means the tree is dirty.
    static func parseDirty(porcelain: String) -> Bool {
        !porcelain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Parses `git rev-list --left-right --count HEAD...@{upstream}` output, which is
    /// two ints separated by a tab: `<ahead>\t<behind>`.
    static func parseAheadBehind(_ output: String) -> (ahead: Int, behind: Int)? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let ahead = Int(parts[0]),
              let behind = Int(parts[1])
        else { return nil }
        return (ahead, behind)
    }
}
