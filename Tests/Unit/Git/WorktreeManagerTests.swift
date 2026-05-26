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
}
