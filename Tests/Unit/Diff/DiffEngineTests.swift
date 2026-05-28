import Foundation
@testable import Yggdrasil
import XCTest

final class DiffEngineTests: XCTestCase {

    private var fixture: FixtureGitRepo!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await FixtureGitRepo.create(named: "diff")
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    private func runGit(_ args: [String]) async throws {
        let runner = ProcessRunner()
        let result = try await runner.run(
            executable: "/usr/bin/git", arguments: ["-C", fixture.repoURL.path] + args
        )
        if result.exitCode != 0 {
            XCTFail("git \(args.joined(separator: " ")) failed: \(result.stderr)")
        }
    }

    func testEmptyDiffReturnsEmptyText() async throws {
        let engine = DiffEngine()
        let diff = try await engine.unifiedDiff(
            worktreePath: fixture.repoURL.path,
            baseRef: "main"
        )
        XCTAssertTrue(diff.text.isEmpty)
        XCTAssertTrue(diff.files.isEmpty)
        XCTAssertFalse(diff.isTruncated)
    }

    func testNewFileShowsUpInDiff() async throws {
        // Create a branch + add a file + commit.
        try await runGit(["checkout", "-b", "feat/new"])
        let path = fixture.repoURL.appendingPathComponent("hello.txt")
        try "hello world\n".write(to: path, atomically: true, encoding: .utf8)
        try await runGit(["add", "hello.txt"])
        try await runGit(["commit", "-m", "add hello"])

        let engine = DiffEngine()
        let diff = try await engine.unifiedDiff(
            worktreePath: fixture.repoURL.path,
            baseRef: "main"
        )

        XCTAssertTrue(diff.text.contains("hello.txt"), "diff should mention the new file path")
        XCTAssertTrue(diff.text.contains("+hello world"), "diff should contain the added line")
        XCTAssertEqual(diff.files, ["hello.txt"])
    }

    func testDeleteShowsUpInDiff() async throws {
        // Add a file on main first.
        let path = fixture.repoURL.appendingPathComponent("doomed.txt")
        try "byeeee\n".write(to: path, atomically: true, encoding: .utf8)
        try await runGit(["add", "doomed.txt"])
        try await runGit(["commit", "-m", "add doomed"])

        try await runGit(["checkout", "-b", "feat/del"])
        try FileManager.default.removeItem(at: path)
        try await runGit(["add", "-A"])
        try await runGit(["commit", "-m", "remove doomed"])

        let engine = DiffEngine()
        let diff = try await engine.unifiedDiff(
            worktreePath: fixture.repoURL.path,
            baseRef: "main"
        )

        XCTAssertTrue(diff.text.contains("doomed.txt"))
        XCTAssertTrue(diff.text.contains("-byeeee"))
    }

    func testUnknownBaseRefThrowsTypedError() async throws {
        let engine = DiffEngine()
        do {
            _ = try await engine.unifiedDiff(
                worktreePath: fixture.repoURL.path,
                baseRef: "this-ref-does-not-exist"
            )
            XCTFail("expected throw")
        } catch DiffEngineError.unknownBaseRef {
            // expected
        } catch {
            XCTFail("expected .unknownBaseRef, got \(error)")
        }
    }

    func testUnstagedWorkingTreeModificationsAppearInDiff() async throws {
        // Commit a file on main first, then branch and modify the file in
        // the working tree WITHOUT committing. The diff viewer should still
        // show the change — previously it didn't, because the engine ran
        // `git diff <base>...HEAD` which only sees commits.
        let path = fixture.repoURL.appendingPathComponent("file.txt")
        try "alpha\n".write(to: path, atomically: true, encoding: .utf8)
        try await runGit(["add", "file.txt"])
        try await runGit(["commit", "-m", "add file"])

        try await runGit(["checkout", "-b", "feat/dirty"])
        // Modify the file without committing.
        try "alpha\nbeta\n".write(to: path, atomically: true, encoding: .utf8)

        let engine = DiffEngine()
        let diff = try await engine.unifiedDiff(
            worktreePath: fixture.repoURL.path,
            baseRef: "main"
        )

        XCTAssertTrue(diff.text.contains("file.txt"), "diff should mention the modified file")
        XCTAssertTrue(diff.text.contains("+beta"), "diff should contain the unstaged added line")
    }

    func testStagedButUncommittedModificationsAppearInDiff() async throws {
        let path = fixture.repoURL.appendingPathComponent("file.txt")
        try "alpha\n".write(to: path, atomically: true, encoding: .utf8)
        try await runGit(["add", "file.txt"])
        try await runGit(["commit", "-m", "add file"])

        try await runGit(["checkout", "-b", "feat/staged"])
        try "alpha\ngamma\n".write(to: path, atomically: true, encoding: .utf8)
        try await runGit(["add", "file.txt"]) // staged, NOT committed

        let engine = DiffEngine()
        let diff = try await engine.unifiedDiff(
            worktreePath: fixture.repoURL.path,
            baseRef: "main"
        )

        XCTAssertTrue(diff.text.contains("file.txt"))
        XCTAssertTrue(diff.text.contains("+gamma"))
    }

    func testLargeDiffIsFlaggedTruncated() async throws {
        try await runGit(["checkout", "-b", "feat/huge"])
        // Write a single >5MB file. Repeated short line so the file gets a
        // useful line count in the diff. Phase 8's async pipe drain in
        // ProcessRunner unblocks this test.
        let path = fixture.repoURL.appendingPathComponent("huge.txt")
        let chunk = String(repeating: "x", count: 64) + "\n" // 65 bytes/line
        let lines = (5 * 1024 * 1024 / chunk.count) + 100 // > 5 MB worth
        let blob = String(repeating: chunk, count: lines)
        try blob.write(to: path, atomically: true, encoding: .utf8)
        try await runGit(["add", "huge.txt"])
        try await runGit(["commit", "-m", "huge"])

        let engine = DiffEngine()
        let diff = try await engine.unifiedDiff(
            worktreePath: fixture.repoURL.path,
            baseRef: "main"
        )
        XCTAssertTrue(diff.isTruncated, "diff over 5MB should be flagged as truncated")
    }
}
