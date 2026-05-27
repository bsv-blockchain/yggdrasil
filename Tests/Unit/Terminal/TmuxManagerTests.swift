import XCTest
@testable import Yggdrasil

/// Pure-logic tests for TmuxManager — no subprocess spawning. Process-level
/// behaviour (has-session, kill-session, list-sessions) is exercised end-to-end
/// via the integration tests / manual verification in the plan.
final class TmuxManagerTests: XCTestCase {
    func test_sessionName_isStablePerTabID() {
        XCTAssertEqual(TmuxManager.sessionName(forTabID: 1), "yggdrasil-tab-1")
        XCTAssertEqual(TmuxManager.sessionName(forTabID: 643), "yggdrasil-tab-643")
        XCTAssertEqual(TmuxManager.sessionName(forTabID: 0), "yggdrasil-tab-0")
    }

    func test_wrapCommand_hasSessionGate_thenAttaches() {
        let manager = TmuxManager(tmuxPath: "/opt/homebrew/bin/tmux")
        let script = manager.wrapCommand(
            tabID: 1, cwd: "/tmp/foo", command: "claude",
            args: [], resumeArgs: []
        )
        XCTAssertTrue(script.contains("has-session -t 'yggdrasil-tab-1'"),
                      "Script should gate creation on has-session: \(script)")
        XCTAssertTrue(script.contains("new-session -d -s 'yggdrasil-tab-1'"),
                      "Script should create with -d -s on first launch")
        XCTAssertTrue(script.contains("exec tmux -L 'yggdrasil' attach -t 'yggdrasil-tab-1'"),
                      "Script must end with `exec tmux attach` so the shell is replaced")
    }

    func test_wrapCommand_embedsResumeArgs() {
        let manager = TmuxManager(tmuxPath: "/usr/local/bin/tmux")
        let script = manager.wrapCommand(
            tabID: 1, cwd: "/tmp/foo", command: "claude",
            args: [], resumeArgs: ["--dangerously-skip-permissions", "--continue"]
        )
        XCTAssertTrue(
            script.contains("--dangerously-skip-permissions"),
            "Resume args must be embedded in the wrap-script's inner command: \(script)"
        )
        XCTAssertTrue(script.contains("--continue"))
    }

    func test_wrapCommand_quotesCwdWithSpaces() {
        let manager = TmuxManager(tmuxPath: "/usr/local/bin/tmux")
        let script = manager.wrapCommand(
            tabID: 7, cwd: "/Users/me/path with space/repo",
            command: "claude", args: [], resumeArgs: []
        )
        XCTAssertTrue(
            script.contains("'/Users/me/path with space/repo'"),
            "Cwd with spaces must be single-quoted: \(script)"
        )
    }

    func test_wrapCommand_setsStatusBarOff() {
        let manager = TmuxManager(tmuxPath: "/usr/local/bin/tmux")
        let script = manager.wrapCommand(
            tabID: 1, cwd: "/tmp/foo", command: "claude",
            args: [], resumeArgs: []
        )
        XCTAssertTrue(
            script.contains("set-option -t 'yggdrasil-tab-1' status off"),
            "Status bar should be disabled on session creation: \(script)"
        )
    }

    func test_parseSessionList_splitsLinesAndDropsBlanks() {
        let out = "yggdrasil-tab-1\nyggdrasil-tab-2\n\nyggdrasil-tab-3\n"
        XCTAssertEqual(
            TmuxManager.parseSessionList(out),
            ["yggdrasil-tab-1", "yggdrasil-tab-2", "yggdrasil-tab-3"]
        )
    }

    func test_parseSessionList_handlesEmpty() {
        XCTAssertEqual(TmuxManager.parseSessionList(""), [])
    }

    func test_parseSessionList_trimsWhitespace() {
        XCTAssertEqual(
            TmuxManager.parseSessionList("  yggdrasil-tab-1  \n\tyggdrasil-tab-2"),
            ["yggdrasil-tab-1", "yggdrasil-tab-2"]
        )
    }

    func test_isAvailable_reflectsTmuxPath() {
        XCTAssertFalse(TmuxManager(tmuxPath: nil).isAvailable)
        XCTAssertTrue(TmuxManager(tmuxPath: "/usr/local/bin/tmux").isAvailable)
    }
}
