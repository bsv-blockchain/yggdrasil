import Foundation

/// Where a `WorktreeManager`'s repos live: this Mac or an ssh host. Covers
/// the few steps that aren't plain git commands; git itself goes through the
/// manager's `GitRunner`, local or over ssh.
protocol WorktreeSite: Sendable {
    /// The main checkout of `repo` at this site, or nil if there is none.
    func mainPath(for repo: Repo) -> String?
    /// Creates `<main>/.worktrees` and lists it in `.git/info/exclude`, so the
    /// in-repo worktrees don't show as untracked in `git status`.
    func prepareWorktreesDir(mainURL: URL) async throws
    /// Serialises worktree creation in a repo across processes.
    func lock(worktreesDir: URL) async throws -> WorktreeLock
    /// `url` in the form git prints worktree paths in.
    func canonicalPath(_ url: URL) -> String
    /// Best-effort cleanup of a directory a failed `worktree add` left behind.
    func removeLeftover(at url: URL) async
    /// Whether a tab may be handed the main checkout itself when its branch is
    /// checked out there.
    var allowsMainCheckout: Bool { get }
}

protocol WorktreeLock {
    func release()
}

extension FileLock: WorktreeLock {}

/// Repos cloned on this Mac (`repo.local_main_path`).
struct LocalWorktreeSite: WorktreeSite {
    let allowsMainCheckout = true

    func mainPath(for repo: Repo) -> String? {
        repo.localMainPath
    }

    func prepareWorktreesDir(mainURL: URL) async throws {
        Self.ensureGitExcludeContainsWorktreesDir(repoURL: mainURL)
        try FileManager.default.createDirectory(
            at: mainURL.appendingPathComponent(".worktrees", isDirectory: true),
            withIntermediateDirectories: true
        )
    }

    /// Per-repo POSIX file lock — cross-process serialisation per spec §Phase 2.
    /// (Same-actor calls are already serialised by actor isolation.) FileLock
    /// uses LOCK_NB + async retry so a contending caller doesn't wedge the
    /// cooperative thread.
    func lock(worktreesDir: URL) async throws -> WorktreeLock {
        try await FileLock.acquireExclusive(at: worktreesDir.appendingPathComponent(".yggdrasil.lock"))
    }

    /// Resolve through symlinks because git outputs canonical paths (e.g.
    /// /private/var/...) but callers build the user-facing form (/var/...).
    func canonicalPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    func removeLeftover(at url: URL) async {
        try? FileManager.default.removeItem(at: url)
    }

    /// Best-effort append of `.worktrees/` to the repo's `.git/info/exclude`.
    /// We touch `.git/info/exclude` (not `.gitignore`) so the change stays
    /// private to the user's checkout and never lands in any commit. Silent
    /// no-op if the file already mentions the line, or if the file can't be
    /// opened for any reason.
    private static func ensureGitExcludeContainsWorktreesDir(repoURL: URL) {
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
}

/// Repos on an ssh host, at `<repos_root>/<owner>/<name>`. Non-git steps run
/// as small sh snippets through `runner` (an `SSHSubprocessRunner` in the app).
///
/// On a host the main checkout is shared by every tab of the repo and only
/// ever holds the default branch; each tab works in its own worktree.
struct RemoteWorktreeSite: WorktreeSite {
    let host: RemoteHost
    let runner: SubprocessRunner
    let allowsMainCheckout = false
    private let checkoutPath: @Sendable (Repo) -> String?

    /// `checkoutPath` is the repo's pinned checkout (`HostRepoStore`);
    /// defaults to `<repos_root>/<owner>/<name>`.
    init(
        host: RemoteHost,
        runner: SubprocessRunner? = nil,
        checkoutPath: (@Sendable (Repo) -> String?)? = nil
    ) {
        self.host = host
        self.runner = runner ?? SSHSubprocessRunner(host: host)
        self.checkoutPath = checkoutPath ?? { [host] repo in host.repoPath(owner: repo.owner, name: repo.name) }
    }

    func mainPath(for repo: Repo) -> String? {
        checkoutPath(repo)
    }

    func prepareWorktreesDir(mainURL: URL) async throws {
        try await sh("""
        mkdir -p "$1/.worktrees"
        if [ -d "$1/.git/info" ] && ! grep -qxF '.worktrees/' "$1/.git/info/exclude" 2>/dev/null; then
            printf '.worktrees/\\n' >> "$1/.git/info/exclude"
        fi
        """, mainURL.path)
    }

    /// No cross-process lock on the host: the manager actor already serialises
    /// this app's calls, and a second Mac creating the same worktree at the
    /// same moment isn't a case we handle.
    func lock(worktreesDir _: URL) async throws -> WorktreeLock {
        NoLock()
    }

    /// The host's symlinks aren't visible from here. If the repos root is
    /// symlinked, the manager matches the existing worktree by branch instead.
    func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// `git worktree add` doesn't leave a directory behind for an unknown ref;
    /// nothing to clean up remotely.
    func removeLeftover(at _: URL) async {}

    /// Clones `repo` into its host path with the host's own `gh` if there's no
    /// checkout there yet. Returns whether it cloned.
    @discardableResult
    func ensureCloned(_ repo: Repo) async throws -> Bool {
        guard let main = mainPath(for: repo) else { return false }
        let output = try await sh("""
        if [ -d "$1/.git" ]; then exit 0; fi
        mkdir -p "$(dirname "$1")"
        gh repo clone "$2" "$1" >/dev/null && echo cloned
        """, main, repo.fullName)
        return output.contains("cloned")
    }

    @discardableResult
    private func sh(_ script: String, _ args: String...) async throws -> String {
        let result = try await runner.run(executable: "sh", arguments: ["-c", script, "sh"] + args)
        guard result.exitCode == 0 else {
            throw WorktreeError.gitFailed(
                stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines),
                exitCode: result.exitCode
            )
        }
        return result.stdout
    }

    private struct NoLock: WorktreeLock {
        func release() {}
    }
}
