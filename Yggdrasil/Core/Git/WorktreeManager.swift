import Foundation

/// Owns git worktree lifecycle for tracked repos. Pure git-subprocess mechanics — no
/// GitHub coupling beyond accepting a `Repo` model.
///
/// Worktrees live at `<parent-of-main-clone>/.worktrees/<branch-slug>` per spec §2.1.
actor WorktreeManager {
    private let git: GitRunner

    init(git: GitRunner = GitRunner()) {
        self.git = git
    }

    // MARK: - Public API

    /// Matches `refs/pull/<N>/head` (the GitHub PR convention). Captures the number.
    private static let pullRefRegex = #"^refs/pull/(\d+)/head$"#

    /// Ensure a worktree for `branch` exists. Idempotent — if the worktree at the
    /// expected path is already on the right branch, returns its URL without doing
    /// any git work.
    ///
    /// - For PR refs (`baseRef` matching `refs/pull/<N>/head`): first runs
    ///   `git fetch origin pull/<N>/head:<branch>` to materialise the local branch,
    ///   then `git worktree add <path> <branch>`.
    /// - For regular refs: `git worktree add -b <branch> <path> <baseRef ?? default>`.
    func ensure(repo: Repo, branch: String, baseRef: String? = nil) async throws -> URL {
        guard let mainPath = repo.localMainPath else {
            throw WorktreeError.parseFailure(reason: "repo \(repo.fullName) has no localMainPath")
        }
        let mainURL = URL(fileURLWithPath: mainPath, isDirectory: true)
        // Place worktrees INSIDE the repo at `<repoPath>/.worktrees/<slug>` so
        // multiple tracked repos can have the same PR number without their
        // worktrees colliding in a shared parent. We auto-extend the repo's
        // `.git/info/exclude` so `.worktrees/` doesn't appear as untracked in
        // git status. Legacy worktrees created under `<parent>/.worktrees/`
        // keep working — the tab row still references the old path and
        // `TabsModel.repoOwning` accepts both conventions.
        let worktreesDir = mainURL.appendingPathComponent(".worktrees", isDirectory: true)
        ensureGitExcludeContainsWorktreesDir(repoURL: mainURL)
        let slug = BranchSlug.slug(for: branch)
        // isDirectory: true so the URL representation is stable regardless of whether
        // the directory exists on disk yet (avoids "/path/foo" vs "/path/foo/" drift
        // between idempotent calls).
        let target = worktreesDir.appendingPathComponent(slug, isDirectory: true)

        // Acquire the per-repo POSIX file lock — cross-process serialisation per spec
        // §Phase 2. (Same-actor calls are already serialised by actor isolation; the
        // flock is purely for cross-process protection.) FileLock uses LOCK_NB + async
        // retry so a contending caller doesn't wedge the cooperative thread.
        let lock = try await FileLock.acquireExclusive(
            at: worktreesDir.appendingPathComponent(".yggdrasil.lock")
        )
        defer { lock.release() }

        // Case 1: a worktree is already registered at `target` — idempotent.
        // Resolve both sides through symlinks because git outputs canonical paths
        // (e.g. /private/var/...) but our `target` is built from the user-facing form
        // (e.g. /var/folders/...).
        let canonicalTarget = target.resolvingSymlinksInPath().path
        let existing = try await listWorktrees(at: mainURL)
        if let match = existing.first(where: {
            $0.path.resolvingSymlinksInPath().path == canonicalTarget
        }) {
            if match.branch == branch || match.branch == nil {
                return target
            }
            throw WorktreeError.existsOnDifferentBranch(
                path: target, found: match.branch ?? "<detached>", expected: branch
            )
        }

        // Case 2: create the .worktrees parent if needed.
        try FileManager.default.createDirectory(
            at: worktreesDir, withIntermediateDirectories: true
        )

        // Case 3a: PR ref → fetch then worktree add (no -b).
        if let baseRef, let prNumber = Self.pullRequestNumber(from: baseRef) {
            do {
                try await git.run(
                    args: ["fetch", "origin", "pull/\(prNumber)/head:\(branch)"],
                    cwd: mainURL
                )
            } catch let WorktreeError.gitFailed(stderr, code) {
                if Self.stderrIndicatesUnknownRef(stderr) {
                    throw WorktreeError.unknownRef(baseRef)
                }
                throw WorktreeError.gitFailed(stderr: stderr, exitCode: code)
            }
            try await git.run(
                args: ["worktree", "add", target.path, branch],
                cwd: mainURL
            )
            return target
        }

        // Case 3b: regular ref → `git worktree add -b <branch> <target> <baseRef ?? default>`.
        let base = baseRef ?? repo.defaultBranch
        do {
            try await git.run(
                args: ["worktree", "add", "-b", branch, target.path, base],
                cwd: mainURL
            )
        } catch let WorktreeError.gitFailed(stderr, code) {
            // Map git's reference-resolution failure to a typed error so callers can
            // distinguish "you typoed the base ref" from arbitrary git failures.
            if Self.stderrIndicatesUnknownRef(stderr) {
                // Best-effort cleanup: in case git left a partial dir behind.
                try? FileManager.default.removeItem(at: target)
                throw WorktreeError.unknownRef(base)
            }
            throw WorktreeError.gitFailed(stderr: stderr, exitCode: code)
        }

        return target
    }

    private static func pullRequestNumber(from baseRef: String) -> Int? {
        let regex = try? NSRegularExpression(pattern: pullRefRegex)
        let range = NSRange(baseRef.startIndex..., in: baseRef)
        guard let match = regex?.firstMatch(in: baseRef, range: range),
              match.numberOfRanges == 2,
              let numberRange = Range(match.range(at: 1), in: baseRef)
        else { return nil }
        return Int(baseRef[numberRange])
    }

    /// `git worktree list --porcelain` parsed into `[WorktreeInfo]`. Includes the
    /// main clone as the first entry.
    func list(for repo: Repo) async throws -> [WorktreeInfo] {
        guard let mainPath = repo.localMainPath else {
            return []
        }
        return try await listWorktrees(at: URL(fileURLWithPath: mainPath, isDirectory: true))
    }

    /// Remove a worktree. Refuses if the worktree is dirty unless `force: true`.
    func remove(repo: Repo, path: URL, force: Bool) async throws {
        guard let mainPath = repo.localMainPath else {
            throw WorktreeError.parseFailure(reason: "repo \(repo.fullName) has no localMainPath")
        }
        let mainURL = URL(fileURLWithPath: mainPath, isDirectory: true)

        if !force {
            let status = try await git.run(args: ["status", "--porcelain"], cwd: path)
            if !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw WorktreeError.dirty(path: path)
            }
        }

        var args = ["worktree", "remove", path.path]
        if force {
            args.append("--force")
        }
        try await git.run(args: args, cwd: mainURL)
    }

    /// `git worktree prune` — drops administrative entries for worktree directories
    /// that no longer exist on disk.
    func cleanupOrphans(for repo: Repo) async throws {
        guard let mainPath = repo.localMainPath else { return }
        let mainURL = URL(fileURLWithPath: mainPath, isDirectory: true)
        try await git.run(args: ["worktree", "prune"], cwd: mainURL)
    }

    // MARK: - Internals

    private func listWorktrees(at mainURL: URL) async throws -> [WorktreeInfo] {
        let result = try await git.run(args: ["worktree", "list", "--porcelain"], cwd: mainURL)
        return try WorktreeInfo.parsePorcelain(result.stdout)
    }

    /// Best-effort append of `.worktrees/` to the repo's `.git/info/exclude`
    /// so the in-repo worktree directory doesn't show up as untracked in
    /// `git status`. We touch `.git/info/exclude` (not `.gitignore`) so the
    /// change stays private to the user's checkout and never lands in any
    /// commit. Silent no-op if the file already mentions the line, or if
    /// the file can't be opened for any reason.
    private func ensureGitExcludeContainsWorktreesDir(repoURL: URL) {
        let excludeURL = repoURL
            .appendingPathComponent(".git", isDirectory: true)
            .appendingPathComponent("info", isDirectory: true)
            .appendingPathComponent("exclude")
        // `.git` may be a file rather than a directory in some worktrees; in
        // that case there is no info/exclude to edit and we just bail.
        var infoDirIsDir: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: excludeURL.deletingLastPathComponent().path, isDirectory: &infoDirIsDir
        ), infoDirIsDir.boolValue else { return }
        let needle = ".worktrees/"
        let existing = (try? String(contentsOf: excludeURL, encoding: .utf8)) ?? ""
        if existing.contains(needle) { return }
        let separator = (existing.isEmpty || existing.hasSuffix("\n")) ? "" : "\n"
        let appended = existing + separator + needle + "\n"
        try? appended.write(to: excludeURL, atomically: true, encoding: .utf8)
    }

    /// Git reference-resolution failure messages we want to map to .unknownRef.
    /// Heuristic matches several flavours of `git`'s wording.
    private static func stderrIndicatesUnknownRef(_ stderr: String) -> Bool {
        let lower = stderr.lowercased()
        return lower.contains("invalid reference")
            || lower.contains("unknown revision")
            || lower.contains("not a valid object")
            || lower.contains("ambiguous argument")
            || lower.contains("fatal: revision walk")
            || lower.contains("not a valid ref")
            || (lower.contains("fatal:") && lower.contains("not a tree object"))
    }
}
