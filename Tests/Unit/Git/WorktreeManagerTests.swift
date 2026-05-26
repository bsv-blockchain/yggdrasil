@testable import Loom
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
