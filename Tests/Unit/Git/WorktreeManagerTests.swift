@testable import Yggdrasil
import XCTest

final class WorktreeManagerTests: XCTestCase {
    private var fixture: FixtureGitRepo!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await FixtureGitRepo.create(named: "teranode")
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    // MARK: - ensure() — new branch from default branch

    func testEnsureCreatesWorktreeAtExpectedPath() async throws {
        let manager = WorktreeManager()
        let path = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        XCTAssertEqual(path.path, fixture.worktreesDir.appendingPathComponent("feat-foo").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "worktree dir should exist on disk")
    }

    func testEnsureIdempotentWhenBranchAlreadyExists() async throws {
        let manager = WorktreeManager()
        let first = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        // Second call with same args must return the same path with no error.
        let second = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        XCTAssertEqual(first, second)
    }

    func testEnsureDiscoversExistingWorktreeAcrossManagerInstances() async throws {
        // Simulate app restart: build worktree with manager A, then construct manager B
        // and verify it sees the existing worktree without recreating it.
        let managerA = WorktreeManager()
        let firstPath = try await managerA.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)

        let managerB = WorktreeManager()
        let secondPath = try await managerB.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        XCTAssertEqual(firstPath, secondPath)
    }

    func testEnsureWithUnknownBaseRefThrowsAndLeavesNoPartialState() async throws {
        let manager = WorktreeManager()
        do {
            _ = try await manager.ensure(
                repo: fixture.repo,
                branch: "feat/from-nowhere",
                baseRef: "this-branch-does-not-exist"
            )
            XCTFail("expected throw")
        } catch WorktreeError.unknownRef {
            // expected
        } catch {
            XCTFail("expected .unknownRef, got \(error)")
        }
        // The expected path should NOT exist on disk after the failed call.
        let expectedPath = fixture.worktreesDir.appendingPathComponent("feat-from-nowhere")
        XCTAssertFalse(FileManager.default.fileExists(atPath: expectedPath.path))
    }

    func testEnsureCreatesWorktreesDirIfMissing() async throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.worktreesDir.path),
                       "precondition: .worktrees dir does not exist yet")
        let manager = WorktreeManager()
        _ = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.worktreesDir.path))
    }

    // MARK: - list()

    func testListIncludesNewlyCreatedWorktree() async throws {
        let manager = WorktreeManager()
        _ = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        _ = try await manager.ensure(repo: fixture.repo, branch: "feat/bar", baseRef: nil)

        let entries = try await manager.list(for: fixture.repo)
        // Should include the main clone plus the two new worktrees.
        XCTAssertEqual(entries.count, 3)
        let branches = Set(entries.compactMap(\.branch))
        XCTAssertTrue(branches.contains("main"))
        XCTAssertTrue(branches.contains("feat/foo"))
        XCTAssertTrue(branches.contains("feat/bar"))
    }

    func testListOnFreshRepoReturnsOnlyMainClone() async throws {
        let manager = WorktreeManager()
        let entries = try await manager.list(for: fixture.repo)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].branch, "main")
    }

    // MARK: - remove()

    func testRemoveCleanWorktreeSucceeds() async throws {
        let manager = WorktreeManager()
        let path = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))

        try await manager.remove(repo: fixture.repo, path: path, force: false)

        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let remaining = try await manager.list(for: fixture.repo)
        XCTAssertFalse(remaining.contains { $0.branch == "feat/foo" })
    }

    func testRemoveDirtyWorktreeWithoutForceThrowsDirty() async throws {
        let manager = WorktreeManager()
        let path = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        // Dirty it: drop a file inside the worktree.
        let scratch = path.appendingPathComponent("hello.txt")
        try Data("hi".utf8).write(to: scratch)

        do {
            try await manager.remove(repo: fixture.repo, path: path, force: false)
            XCTFail("expected throw")
        } catch let WorktreeError.dirty(reportedPath) {
            XCTAssertEqual(
                reportedPath.resolvingSymlinksInPath().path,
                path.resolvingSymlinksInPath().path
            )
        } catch {
            XCTFail("expected .dirty, got \(error)")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path),
                      "dirty worktree must not be removed")
    }

    func testRemoveDirtyWorktreeWithForceSucceeds() async throws {
        let manager = WorktreeManager()
        let path = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        let scratch = path.appendingPathComponent("hello.txt")
        try Data("hi".utf8).write(to: scratch)

        try await manager.remove(repo: fixture.repo, path: path, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    // MARK: - cleanupOrphans()

    // MARK: - PR branch fetch (stubbed git)

    /// Exercises the PR-ref code path with a StubSubprocessRunner so we don't need
    /// to set up a 2-repo origin with `refs/pull/<n>/head` actually present.
    func testEnsurePullRequestRefIssuesFetchThenWorktreeAdd() async throws {
        let stub = StubSubprocessRunner(responses: [
            // 1. `git worktree list --porcelain` — return just the main clone.
            SubprocessResult(
                stdout: """
                worktree /tmp/repo
                HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                branch refs/heads/main

                """,
                stderr: "", exitCode: 0
            ),
            // 2. `git fetch origin pull/655/head:pr-655` — succeeds silently.
            SubprocessResult(stdout: "", stderr: "", exitCode: 0),
            // 3. `git worktree add /tmp/.worktrees/pr-655 pr-655` — succeeds.
            SubprocessResult(stdout: "", stderr: "", exitCode: 0)
        ])
        let manager = WorktreeManager(git: GitRunner(runner: stub, gitExecutable: "/usr/bin/git"))
        let repo = Repo(
            id: 1, owner: "bsv-blockchain", name: "teranode",
            defaultBranch: "main", localMainPath: "/tmp/repo", addedAt: Date()
        )
        _ = try await manager.ensure(repo: repo, branch: "pr-655", baseRef: "refs/pull/655/head")

        let calls = await stub.recordedCalls()
        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(calls[0].arguments, ["-C", "/tmp/repo", "worktree", "list", "--porcelain"])
        XCTAssertEqual(
            calls[1].arguments,
            ["-C", "/tmp/repo", "fetch", "origin", "pull/655/head:pr-655"]
        )
        XCTAssertEqual(calls[2].arguments[0 ..< 5], ["-C", "/tmp/repo", "worktree", "add", "/tmp/repo/.worktrees/pr-655"])
        XCTAssertEqual(calls[2].arguments.last, "pr-655")
        // Crucially: no `-b` flag on the worktree add step (the branch already exists
        // locally after the fetch).
        XCTAssertFalse(calls[2].arguments.contains("-b"))
    }

    func testEnsurePullRequestRefUnknownPullSurfacesUnknownRef() async throws {
        let stub = StubSubprocessRunner(responses: [
            SubprocessResult(
                stdout: """
                worktree /tmp/repo
                HEAD aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
                branch refs/heads/main

                """,
                stderr: "", exitCode: 0
            ),
            // Fetch fails with the "unknown revision" wording.
            SubprocessResult(
                stdout: "",
                stderr: "fatal: couldn't find remote ref pull/9999/head\nfatal: unknown revision",
                exitCode: 128
            )
        ])
        let manager = WorktreeManager(git: GitRunner(runner: stub, gitExecutable: "/usr/bin/git"))
        let repo = Repo(
            id: 1, owner: "x", name: "y",
            defaultBranch: "main", localMainPath: "/tmp/repo", addedAt: Date()
        )
        do {
            _ = try await manager.ensure(repo: repo, branch: "pr-9999", baseRef: "refs/pull/9999/head")
            XCTFail("expected throw")
        } catch let WorktreeError.unknownRef(ref) {
            XCTAssertEqual(ref, "refs/pull/9999/head")
        } catch {
            XCTFail("expected .unknownRef, got \(error)")
        }
    }

    // MARK: - Concurrency

    func testConcurrentEnsureCallsAreSerialisedAndBothSucceed() async throws {
        let manager = WorktreeManager()
        async let pathFoo = manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        async let pathBar = manager.ensure(repo: fixture.repo, branch: "feat/bar", baseRef: nil)
        let foo = try await pathFoo
        let bar = try await pathBar

        XCTAssertNotEqual(foo, bar)
        let list = try await manager.list(for: fixture.repo)
        let branches = Set(list.compactMap(\.branch))
        XCTAssertTrue(branches.contains("feat/foo"))
        XCTAssertTrue(branches.contains("feat/bar"))
        XCTAssertTrue(branches.contains("main"))
        XCTAssertEqual(list.count, 3)
    }

    func testCleanupOrphansRemovesAdminEntryForDeletedWorktreeDir() async throws {
        let manager = WorktreeManager()
        let path = try await manager.ensure(repo: fixture.repo, branch: "feat/foo", baseRef: nil)
        let preCount = try await manager.list(for: fixture.repo).count
        XCTAssertEqual(preCount, 2)

        // User nuked the worktree directory out from under git (the orphan case).
        try FileManager.default.removeItem(at: path)
        // Until prune, git still lists it (as `prunable`).

        try await manager.cleanupOrphans(for: fixture.repo)

        // After prune, the worktree is no longer in the registry.
        let remaining = try await manager.list(for: fixture.repo)
        XCTAssertFalse(remaining.contains { $0.branch == "feat/foo" }, "stale entry should be pruned")
    }
}
