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

/// Wraps `git diff <baseRef>...HEAD` to produce a unified diff. Note: the spec
/// nominally calls for `SwiftGit2 / libgit2` here, but we ship the subprocess
/// path for Phase 7 to keep the surface minimal — the same `Clibgit2` dep is
/// already linked (Phase 0) and could replace this later. Decision logged in
/// `decisions.md`.
struct DiffEngine {
    /// 5 MB cap per spec §Phase 7 "Large diffs (> 5MB patch)".
    static let truncationLimit = 5 * 1024 * 1024

    let git: GitRunner

    init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    /// Compute the diff between `baseRef` (e.g. `main`, `origin/main`,
    /// `refs/heads/feat/x`) and the worktree's CURRENT state inside
    /// `worktreePath` — that is, the merge-base of `baseRef` and HEAD
    /// versus everything tracked in the working tree (committed, staged,
    /// AND unstaged).
    ///
    /// Implementation: `git diff <merge-base-sha>` (single-commit form).
    /// Git's three-dot form `<base>...HEAD` only sees commits, so any
    /// uncommitted edits the user was about to land never showed up.
    /// Resolving the merge-base ourselves and feeding it to the
    /// single-commit `git diff` keeps GitHub's "PR base" semantics while
    /// also pulling in the working-tree changes the user is actively
    /// editing.
    func unifiedDiff(worktreePath: String, baseRef: String) async throws -> UnifiedDiff {
        let cwd = URL(fileURLWithPath: worktreePath, isDirectory: true)
        // Merge-base; falls back to the literal baseRef when the histories
        // share no common ancestor (rare — typically unrelated repos).
        let mergeBase: String
        do {
            let result = try await git.run(args: ["merge-base", baseRef, "HEAD"], cwd: cwd)
            let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            mergeBase = trimmed.isEmpty ? baseRef : trimmed
        } catch let WorktreeError.gitFailed(stderr, code) {
            if Self.stderrIndicatesUnknownRef(stderr) {
                throw DiffEngineError.unknownBaseRef(baseRef)
            }
            throw DiffEngineError.gitFailed(stderr: stderr, exitCode: code)
        }
        do {
            let result = try await git.run(
                args: [
                    "diff", "--no-color", "--no-ext-diff",
                    "--find-renames",
                    mergeBase,
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
