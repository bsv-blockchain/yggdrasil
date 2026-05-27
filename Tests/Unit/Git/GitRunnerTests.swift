@testable import Yggdrasil
import XCTest

final class GitRunnerTests: XCTestCase {
    func testInvokesGitWithGivenArgsAndCwd() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "git version 2.43.0\n", stderr: "", exitCode: 0)
        ])
        let git = GitRunner(runner: runner, gitExecutable: "/usr/bin/git")
        let cwd = URL(fileURLWithPath: "/tmp/repo")

        _ = try await git.run(args: ["--version"], cwd: cwd)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].executable, "/usr/bin/git")
        // Args include the cwd switch ("-C <cwd>") plus the requested args.
        XCTAssertEqual(calls[0].arguments, ["-C", "/tmp/repo", "--version"])
    }

    func testOmitsCwdSwitchWhenCwdIsNil() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "", exitCode: 0)
        ])
        let git = GitRunner(runner: runner, gitExecutable: "/usr/bin/git")
        _ = try await git.run(args: ["init", "/tmp/foo"], cwd: nil)
        let calls = await runner.recordedCalls()
        XCTAssertEqual(calls[0].arguments, ["init", "/tmp/foo"])
    }

    func testNonZeroExitThrowsGitFailed() async {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "not a git repo", exitCode: 128)
        ])
        let git = GitRunner(runner: runner, gitExecutable: "/usr/bin/git")
        do {
            _ = try await git.run(args: ["status"], cwd: nil)
            XCTFail("expected throw")
        } catch let WorktreeError.gitFailed(stderr, code) {
            XCTAssertEqual(stderr, "not a git repo")
            XCTAssertEqual(code, 128)
        } catch {
            XCTFail("expected .gitFailed, got \(error)")
        }
    }

    func testZeroExitReturnsStdout() async throws {
        let runner = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "main\n", stderr: "", exitCode: 0)
        ])
        let git = GitRunner(runner: runner, gitExecutable: "/usr/bin/git")
        let result = try await git.run(args: ["symbolic-ref", "--short", "HEAD"], cwd: nil)
        XCTAssertEqual(result.stdout, "main\n")
    }
}

final class WorktreeInfoTests: XCTestCase {
    func testParsesPorcelainOutputForSingleWorktree() throws {
        // Output of `git worktree list --porcelain` for a fresh repo.
        let porcelain = """
        worktree /Users/x/code/teranode
        HEAD a1b2c3d4e5f6789012345678901234567890abcd
        branch refs/heads/main

        """
        let infos = try WorktreeInfo.parsePorcelain(porcelain)
        XCTAssertEqual(infos.count, 1)
        XCTAssertEqual(infos[0].path.path, "/Users/x/code/teranode")
        XCTAssertEqual(infos[0].head, "a1b2c3d4e5f6789012345678901234567890abcd")
        XCTAssertEqual(infos[0].branch, "main")
        XCTAssertFalse(infos[0].isBare)
        XCTAssertFalse(infos[0].isLocked)
        XCTAssertFalse(infos[0].isPrunable)
    }

    func testParsesPorcelainOutputForMultipleWorktrees() throws {
        let porcelain = """
        worktree /Users/x/code/teranode
        HEAD a1b2c3d4e5f6789012345678901234567890abcd
        branch refs/heads/main

        worktree /Users/x/code/.worktrees/feat-foo
        HEAD 1111111111111111111111111111111111111111
        branch refs/heads/feat/foo

        worktree /Users/x/code/.worktrees/pr-42
        HEAD 2222222222222222222222222222222222222222
        detached

        """
        let infos = try WorktreeInfo.parsePorcelain(porcelain)
        XCTAssertEqual(infos.count, 3)
        XCTAssertEqual(infos[1].branch, "feat/foo")
        XCTAssertEqual(infos[2].branch, nil)
        XCTAssertEqual(infos[2].head, "2222222222222222222222222222222222222222")
    }

    func testParsesLockedAndPrunableFlags() throws {
        let porcelain = """
        worktree /Users/x/code/.worktrees/stale
        HEAD 3333333333333333333333333333333333333333
        branch refs/heads/stale
        locked because user said so
        prunable

        """
        let infos = try WorktreeInfo.parsePorcelain(porcelain)
        XCTAssertEqual(infos.count, 1)
        XCTAssertTrue(infos[0].isLocked)
        XCTAssertTrue(infos[0].isPrunable)
    }

    func testEmptyOutputReturnsEmptyArray() throws {
        XCTAssertEqual(try WorktreeInfo.parsePorcelain(""), [])
    }
}
