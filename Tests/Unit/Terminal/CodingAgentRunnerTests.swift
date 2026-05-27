@testable import Loom
import XCTest

final class CodingAgentRunnerTests: XCTestCase {

    private var db: LoomDatabase!
    private var sessionStore: SessionStateStore!
    private var tabID: Int64!

    override func setUpWithError() throws {
        db = try LoomDatabase.inMemory()
        sessionStore = SessionStateStore(database: db)
        // Create a tab row to associate sessions with.
        tabID = try db.queue.write { db in
            var tab = LoomTab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "scratch", worktreePath: NSTemporaryDirectory(),
                lastMainView: .agent, createdAt: Date(), lastActiveAt: Date()
            )
            try tab.insert(db)
            return tab.id!
        }
    }

    override func tearDown() {
        db = nil
        sessionStore = nil
        tabID = nil
        super.tearDown()
    }

    /// The spec's acceptance criterion: unit test for PTY supervisor lifecycle
    /// using `/bin/echo` as a stand-in agent command. Verifies that:
    ///   - the process spawns,
    ///   - its stdout is captured into the OutputRingBuffer,
    ///   - the process terminates,
    ///   - SessionStateStore records the exit code and pty_ended_at.
    func testEchoSpawnsAndExitsCleanWithCapturedOutput() async throws {
        let runner = CodingAgentRunner(
            tabID: tabID,
            cwd: NSTemporaryDirectory(),
            command: "/bin/echo",
            args: ["hello", "loom"],
            sessionStore: sessionStore
        )

        try runner.start()
        try await runner.waitUntilExited(timeout: .seconds(5))

        // Exit code is set on the runner.
        XCTAssertEqual(runner.lastExitCode, 0)

        // Session state row reflects the lifecycle.
        let state = try XCTUnwrap(try sessionStore.get(tabID: tabID))
        XCTAssertEqual(state.agentCommand, "/bin/echo")
        XCTAssertEqual(state.agentArgs, ["hello", "loom"])
        XCTAssertEqual(state.lastKnownExitCode, 0)
        XCTAssertNotNil(state.ptyEndedAt)

        // Output ring saw the echo'd line.
        let captured = String(data: runner.capturedOutput(), encoding: .utf8) ?? ""
        XCTAssertTrue(captured.contains("hello loom"),
                      "ring should contain echo output; got: \(captured.debugDescription)")
    }

    /// `terminate(graceful: true)` sends SIGTERM. A long-running process must die
    /// promptly when asked nicely.
    /// `terminate(graceful: false)` sends SIGKILL immediately. The PTY-spawned
    /// process dies and `processTerminated` fires.
    func testTerminateUngracefullyEndsLongRunningProcess() async throws {
        let runner = CodingAgentRunner(
            tabID: tabID,
            cwd: NSTemporaryDirectory(),
            command: "/bin/sleep",
            args: ["30"],
            sessionStore: sessionStore
        )
        try runner.start()
        try await Task.sleep(for: .milliseconds(200))

        runner.terminate(graceful: false)

        try await runner.waitUntilExited(timeout: .seconds(5))
        XCTAssertNotNil(runner.lastExitCode, "process should have exited")
        let state = try XCTUnwrap(try sessionStore.get(tabID: tabID))
        XCTAssertNotNil(state.ptyEndedAt)
    }

    /// `terminate(graceful: true)` sends SIGTERM. Falls back to SIGKILL after
    /// `killAfter` if the process refuses to die. Verifies the killAfter path —
    /// the test runner uses a small killAfter so the test runs quickly.
    func testTerminateGracefullyFallsBackToSigkillForStubbornProcess() async throws {
        // A shell that traps SIGTERM and keeps sleeping is the realistic worst case
        // a graceful terminate must still defeat.
        let runner = CodingAgentRunner(
            tabID: tabID,
            cwd: NSTemporaryDirectory(),
            command: "/bin/sh",
            args: ["-c", "trap '' TERM; sleep 30"],
            sessionStore: sessionStore,
            killAfter: .milliseconds(300)
        )
        try runner.start()
        try await Task.sleep(for: .milliseconds(200))

        runner.terminate(graceful: true)

        try await runner.waitUntilExited(timeout: .seconds(5))
        XCTAssertNotNil(runner.lastExitCode, "process should have been SIGKILL'd")
    }

    /// Session state is written at start (with pty_started_at, exit-code nil) and
    /// updated at end. Restart scenario: a fresh runner replaces the prior state.
    func testRestartReplacesPriorSessionState() async throws {
        let runner1 = CodingAgentRunner(
            tabID: tabID, cwd: NSTemporaryDirectory(),
            command: "/bin/echo", args: ["first"],
            sessionStore: sessionStore
        )
        try runner1.start()
        try await runner1.waitUntilExited(timeout: .seconds(5))

        let firstState = try XCTUnwrap(try sessionStore.get(tabID: tabID))
        XCTAssertEqual(firstState.agentCommand, "/bin/echo")
        XCTAssertEqual(firstState.agentArgs, ["first"])

        let runner2 = CodingAgentRunner(
            tabID: tabID, cwd: NSTemporaryDirectory(),
            command: "/bin/echo", args: ["second"],
            sessionStore: sessionStore
        )
        try runner2.start()
        try await runner2.waitUntilExited(timeout: .seconds(5))

        let secondState = try XCTUnwrap(try sessionStore.get(tabID: tabID))
        XCTAssertEqual(secondState.agentArgs, ["second"])
        let rowCount = try await db.queue.read { db in try SessionState.fetchCount(db) }
        XCTAssertEqual(rowCount, 1, "single tab → single session_state row, updated in place")
    }
}
