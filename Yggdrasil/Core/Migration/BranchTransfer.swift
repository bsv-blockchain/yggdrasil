import Foundation

enum MigrationError: Error, Equatable {
    /// Only committed work moves; the worktree has changes or untracked files.
    case dirtyWorktree(String)
    /// The branch moved on both sides; nothing is overwritten.
    case branchDiverged(String)
    case sameLocation
    /// Branches move between this Mac and a host; host to host isn't supported.
    case hostToHost
    /// Moving to this Mac needs the repo cloned here.
    case noLocalClone(String)
    case transcriptCopyFailed(String)
}

/// Moves a tab's branch between two checkouts of the same repo, over ssh when
/// one of them is on a host. The sending side's commits land on a scratch ref
/// (`refs/ygg/migrate/<branch>`) in the receiving checkout, then `adopt`
/// moves the branch there — fast-forward only, so work that exists only on
/// the receiving side is never overwritten.
enum BranchTransfer {
    static func scratchRef(_ branch: String) -> String {
        "refs/ygg/migrate/\(branch)"
    }

    /// `ssh://<target><path>` — works for ~/.ssh/config aliases and user@host.
    static func url(host: RemoteHost, path: String) -> String {
        "ssh://\(host.sshTarget)\(path)"
    }

    /// git's ssh, sharing the app's connection to the host. BatchMode: there's
    /// no terminal to answer a prompt.
    static var sshCommand: String {
        ([SSHCommand.executable] + SSHCommand.options(controlDirectory: SSHCommand.defaultControlDirectory)
            + ["-o", "BatchMode=yes"]).joined(separator: " ")
    }

    /// Sends `branch` from a local worktree to the scratch ref at `remote`.
    static func push(branch: String, from worktree: URL, to remote: String, git: GitRunner) async throws {
        SSHCommand.prepareControlDirectory()
        try await git.run(
            args: ["-c", "core.sshCommand=\(sshCommand)", "push", "--quiet", remote,
                   "+refs/heads/\(branch):\(scratchRef(branch))"],
            cwd: worktree
        )
    }

    /// Pulls `branch` from `remote` into the scratch ref of a local checkout.
    static func fetch(branch: String, from remote: String, into checkout: URL, git: GitRunner) async throws {
        SSHCommand.prepareControlDirectory()
        try await git.run(
            args: ["-c", "core.sshCommand=\(sshCommand)", "fetch", "--quiet", remote,
                   "+refs/heads/\(branch):\(scratchRef(branch))"],
            cwd: checkout
        )
    }

    /// Moves `branch` in `checkout` (via `git`, local or over ssh) to the
    /// scratch ref, fast-forward only. A worktree that has the branch checked
    /// out is fast-forwarded in place; otherwise the ref is created or moved.
    /// The scratch ref is removed either way.
    static func adopt(branch: String, checkout: URL, git: GitRunner) async throws {
        let scratch = scratchRef(branch)
        do {
            let listing = try await git.run(args: ["worktree", "list", "--porcelain"], cwd: checkout)
            if let worktree = try WorktreeInfo.parsePorcelain(listing.stdout).first(where: { $0.branch == branch }) {
                try await git.run(args: ["merge", "--ff-only", "--quiet", scratch], cwd: worktree.path)
            } else {
                // No `+`: fetch refuses anything but a fast-forward.
                try await git.run(args: ["fetch", "--quiet", ".", "\(scratch):refs/heads/\(branch)"], cwd: checkout)
            }
        } catch let WorktreeError.gitFailed(stderr, code) {
            _ = try? await git.run(args: ["update-ref", "-d", scratch], cwd: checkout)
            if isNonFastForward(stderr) { throw MigrationError.branchDiverged(branch) }
            throw WorktreeError.gitFailed(stderr: stderr, exitCode: code)
        }
        try await git.run(args: ["update-ref", "-d", scratch], cwd: checkout)
    }

    private static func isNonFastForward(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("non-fast-forward") || lower.contains("not possible to fast-forward")
            || lower.contains("rejected") || lower.contains("diverging")
    }
}
