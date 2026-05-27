import Foundation
@testable import Loom
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

    // Large-diff truncation (`isTruncated`) is checked against
    // DiffEngine.truncationLimit (5 MB) in source. We do not exercise it from
    // a test because the current ProcessRunner drains pipes only in the
    // termination handler — a >5 MB git diff fills the pipe buffer and
    // deadlocks the child. A separate pipe-drain refactor is logged as a
    // follow-up before a real large-diff integration test is safe.
}
