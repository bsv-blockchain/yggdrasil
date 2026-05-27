import Foundation

enum WorktreeError: Error, Equatable {
    /// `git status --porcelain` reports modifications in this worktree and `force: true`
    /// was not passed.
    case dirty(path: URL)
    /// Asked to base a new branch on a ref that doesn't exist (e.g. an upstream that
    /// was never fetched, or a typo in the branch name).
    case unknownRef(String)
    /// A `git` invocation returned non-zero exit. Carries stderr + the exit code.
    case gitFailed(stderr: String, exitCode: Int32)
    /// Worktree was expected at this path but already exists on a different branch.
    case existsOnDifferentBranch(path: URL, found: String, expected: String)
    /// Could not acquire the per-repo file lock within the deadline.
    case lockTimeout(path: URL)
    /// Could not parse `git worktree list --porcelain` output.
    case parseFailure(reason: String)
}
