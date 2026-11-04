import XCTest
@testable import Yggdrasil

/// Correctness of `ProcessRunner` — especially that output is never truncated.
/// The concurrency + large-output tests guard the race that made subprocess
/// tests (git worktree ops, `currentBranch`, agent echo) flake: the terminated
/// pipe drain used to race the readability callback on the same descriptor.
final class SubprocessTests: XCTestCase {
    func testCapturesStdoutExactly() async throws {
        let result = try await ProcessRunner().run(executable: "/bin/echo", arguments: ["hello world"])
        XCTAssertEqual(result.stdout, "hello world\n")
        XCTAssertEqual(result.stderr, "")
        XCTAssertEqual(result.exitCode, 0)
    }

    func testExitCodePropagates() async throws {
        let result = try await ProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "exit 3"])
        XCTAssertEqual(result.exitCode, 3)
    }

    func testStderrCaptured() async throws {
        let result = try await ProcessRunner().run(
            executable: "/bin/sh", arguments: ["-c", "echo oops 1>&2"]
        )
        XCTAssertEqual(result.stdout, "")
        XCTAssertEqual(result.stderr, "oops\n")
    }

    func testLargeStdoutNotTruncated() async throws {
        // 128 KB — larger than the 64 KB pipe buffer, exercising the continuous
        // drain (a single terminal read would deadlock).
        let result = try await ProcessRunner().run(
            executable: "/bin/dd", arguments: ["if=/dev/zero", "bs=1024", "count=128"]
        )
        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.utf8.count, 128 * 1024, "no bytes lost draining a >64KB stream")
    }

    func testLaunchFailureThrows() async {
        do {
            _ = try await ProcessRunner().run(executable: "/nope/not-a-binary", arguments: [])
            XCTFail("expected launch failure")
        } catch ProcessRunner.Error.launchFailed {
            // expected
        } catch {
            XCTFail("expected launchFailed, got \(error)")
        }
    }

    func testConcurrentRunsEachGetTheirOwnCompleteOutput() async throws {
        // Many processes at once, each emitting a unique sizeable payload; every
        // result must match its own input exactly — no truncation, no cross-talk.
        let count = 30
        try await withThrowingTaskGroup(of: (Int, SubprocessResult).self) { group in
            for index in 0 ..< count {
                group.addTask {
                    let token = "tok-\(index)-" + String(repeating: "x", count: 300)
                    let result = try await ProcessRunner().run(executable: "/bin/echo", arguments: [token])
                    return (index, result)
                }
            }
            for try await (index, result) in group {
                let token = "tok-\(index)-" + String(repeating: "x", count: 300)
                XCTAssertEqual(result.stdout, token + "\n", "run \(index) returned truncated/wrong stdout")
                XCTAssertEqual(result.exitCode, 0)
            }
        }
    }

    // MARK: - Cancellation

    /// The status poller's deadline relies on this: without it a hung `ssh`
    /// or `git` keeps the task group (and the whole sweep) waiting.
    func testTerminatesChildOnCancelWhenAsked() async throws {
        let start = Date()
        let task = Task {
            try await ProcessRunner(terminatesOnCancel: true).run(executable: "/bin/sleep", arguments: ["10"])
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    /// ssh through a ControlMaster hands its pipes to the mux master, which
    /// keeps them open until the remote command ends — long after the killed
    /// client is gone. A background grandchild holding the pipes reproduces
    /// that: cancellation must not wait for EOF.
    func testCancelDoesNotWaitForPipesHeldByAnotherProcess() async throws {
        let start = Date()
        let task = Task {
            try await ProcessRunner(terminatesOnCancel: true)
                .run(executable: "/bin/sh", arguments: ["-c", "(trap \"\" TERM; sleep 8) & wait"])
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testAlreadyCancelledTaskDoesNotLaunch() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("ygg-cancel-\(UUID())").path
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner(terminatesOnCancel: true)
                .run(executable: "/usr/bin/touch", arguments: [marker])
        }
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    /// Opt-in only: other callers (worktree creation from a SwiftUI `.task`,
    /// say) must not have a half-finished git command killed under them.
    func testDefaultRunnerLetsChildFinishWhenCancelled() async throws {
        let task = Task {
            try await ProcessRunner().run(executable: "/bin/sh", arguments: ["-c", "sleep 0.5; echo done"])
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = try await task.value
        XCTAssertEqual(result.stdout, "done\n")
    }
}
