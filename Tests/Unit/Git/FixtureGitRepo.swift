import Foundation
@testable import Yggdrasil

/// Sets up a real on-disk git repo for tests that need to exercise the worktree
/// machinery against an actual `git` process.
///
/// Lifecycle:
/// 1. `try await FixtureGitRepo.create(named:)` makes a unique tmp dir,
///    `git init`s a repo inside it, configures user.name/email, and makes
///    an initial commit.
/// 2. The returned `FixtureGitRepo` exposes the `Repo` model row (with
///    `localMainPath` populated) and the parent dir where worktrees will live.
/// 3. Call `cleanup()` (or rely on tearDown) to `rm -rf` the temp tree.
struct FixtureGitRepo {
    let parent: URL
    let repoURL: URL
    let repo: Repo

    static func create(named name: String = "fixture") async throws -> FixtureGitRepo {
        let parent = try makeTempDir(prefix: "yggdrasil-fixture-\(name)-")
        let repoURL = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repoURL, withIntermediateDirectories: true)

        let runner = ProcessRunner()
        // git init -b main
        _ = try await runner.runOrThrow(args: ["init", "-b", "main"], cwd: repoURL)
        // identity (required for commit)
        _ = try await runner.runOrThrow(args: ["config", "user.email", "fixture@yggdrasil.test"], cwd: repoURL)
        _ = try await runner.runOrThrow(args: ["config", "user.name", "Yggdrasil Fixture"], cwd: repoURL)
        // empty initial commit
        _ = try await runner.runOrThrow(
            args: ["commit", "--allow-empty", "-m", "init"], cwd: repoURL
        )

        let repo = Repo(
            id: 1, owner: "fixture", name: name,
            defaultBranch: "main", localMainPath: repoURL.path,
            addedAt: Date()
        )
        return FixtureGitRepo(parent: parent, repoURL: repoURL, repo: repo)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: parent)
    }

    /// Canonical worktrees dir: now inside the repo
    /// (`<repo>/.worktrees/`). Pre-rename this lived at the parent dir as
    /// `<parent>/.worktrees/`, but that allowed PR-number collisions across
    /// repos sharing a parent — see WorktreeManager.ensure for context.
    var worktreesDir: URL {
        repoURL.appendingPathComponent(".worktrees")
    }
}

private func makeTempDir(prefix: String) throws -> URL {
    let baseTmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    let dir = baseTmp.appendingPathComponent("\(prefix)\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

extension ProcessRunner {
    /// Run a git command; throw `RuntimeError(stderr, exitCode)` on non-zero exit.
    /// (Used only by fixtures — production code uses GitRunner.)
    func runOrThrow(args: [String], cwd: URL) async throws -> SubprocessResult {
        let result = try await run(executable: "/usr/bin/git", arguments: ["-C", cwd.path] + args)
        guard result.exitCode == 0 else {
            throw NSError(
                domain: "FixtureGitRepo", code: Int(result.exitCode),
                userInfo: [
                    NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(result.stderr)"
                ]
            )
        }
        return result
    }
}
