import Foundation

/// Computed diff for one worktree vs a base ref.
struct UnifiedDiff: Equatable {
    /// The raw unified-diff text (concatenated `--- a/foo +++ b/foo` blocks).
    /// Empty when there are no changes.
    let text: String
    /// File paths that appear in the diff (post-name when a file was renamed).
    let files: [String]
    /// True when the diff exceeded the size cap (5 MB per spec §Phase 7). The
    /// text is still present but the UI should surface "Diff too large".
    let isTruncated: Bool
}

enum DiffEngineError: Error, Equatable {
    case unknownBaseRef(String)
    case gitFailed(stderr: String, exitCode: Int32)
}

/// Which slice of "what changed" the user wants to see.
enum DiffScope: String, Equatable {
    /// Working tree + index, relative to HEAD. "Everything not committed
    /// yet." Equivalent to `git diff HEAD`.
    case uncommitted
    /// Everything that distinguishes this branch from `baseRef`:
    /// committed changes since the merge-base PLUS working tree + index.
    /// Equivalent to `git diff <merge-base>` (the merge-base is the
    /// branch divergence point with `baseRef`).
    case branchAndUncommitted
}

/// Wraps `git diff` to produce a unified diff. Note: the spec nominally calls
/// for `SwiftGit2 / libgit2` here, but we ship the subprocess path for Phase 7
/// to keep the surface minimal — the same `Clibgit2` dep is already linked
/// (Phase 0) and could replace this later. Decision logged in `decisions.md`.
struct DiffEngine {
    /// 5 MB cap per spec §Phase 7 "Large diffs (> 5MB patch)".
    static let truncationLimit = 5 * 1024 * 1024

    let git: GitRunner

    init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Compute the diff in `worktreePath`. The semantics depend on `scope`:
    ///
    /// - `.uncommitted` — `git diff HEAD`. Only working-tree + staged
    ///   changes that haven't landed in a commit yet. `baseRef` is
    ///   ignored.
    /// - `.branchAndUncommitted` — `git diff <merge-base-of-baseRef-and-HEAD>`.
    ///   Everything that distinguishes the current branch from `baseRef`,
    ///   including committed changes since divergence AND uncommitted
    ///   working-tree edits.
    func unifiedDiff(
        worktreePath: String, baseRef: String, scope: DiffScope = .branchAndUncommitted
    ) async throws -> UnifiedDiff {
        let cwd = URL(fileURLWithPath: worktreePath, isDirectory: true)
        let diffArg: String
        switch scope {
        case .uncommitted:
            diffArg = "HEAD"
        case .branchAndUncommitted:
            // Merge-base; falls back to the literal baseRef when the
            // histories share no common ancestor (rare — typically
            // unrelated repos).
            do {
                let result = try await git.run(args: ["merge-base", baseRef, "HEAD"], cwd: cwd)
                let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                diffArg = trimmed.isEmpty ? baseRef : trimmed
            } catch let WorktreeError.gitFailed(stderr, code) {
                if Self.stderrIndicatesUnknownRef(stderr) {
                    throw DiffEngineError.unknownBaseRef(baseRef)
                }
                throw DiffEngineError.gitFailed(stderr: stderr, exitCode: code)
            }
        }
        do {
            let result = try await git.run(
                args: [
                    "diff", "--no-color", "--no-ext-diff",
                    "--find-renames",
                    diffArg
                ],
                cwd: cwd
            )
            let text = result.stdout
            let truncated = text.utf8.count > Self.truncationLimit
            let files = Self.fileNames(fromUnifiedDiff: text)
            return UnifiedDiff(text: text, files: files, isTruncated: truncated)
        } catch let WorktreeError.gitFailed(stderr, code) {
            if Self.stderrIndicatesUnknownRef(stderr) {
                throw DiffEngineError.unknownBaseRef(baseRef)
            }
            throw DiffEngineError.gitFailed(stderr: stderr, exitCode: code)
        }
    }

    /// Returns the worktree's currently-checked-out branch name (short
    /// form, e.g. `feat/foo`). Nil if HEAD is detached.
    func currentBranch(worktreePath: String) async -> String? {
        let cwd = URL(fileURLWithPath: worktreePath, isDirectory: true)
        guard let result = try? await git.run(
            args: ["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: cwd
        ) else { return nil }
        let name = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func stderrIndicatesUnknownRef(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("unknown revision")
            || lower.contains("ambiguous argument")
            || lower.contains("bad revision")
            || lower.contains("not a valid")
    }

    /// Extracts the `+++ b/<path>` lines from unified-diff text. Strips the
    /// `b/` prefix. `/dev/null` (file deletion) is skipped.
    static func fileNames(fromUnifiedDiff diff: String) -> [String] {
        var out: [String] = []
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.hasPrefix("+++ ") else { continue }
            var name = String(line.dropFirst("+++ ".count))
            if name == "/dev/null" { continue }
            if name.hasPrefix("b/") { name = String(name.dropFirst(2)) }
            out.append(name)
        }
        return out
    }
}
