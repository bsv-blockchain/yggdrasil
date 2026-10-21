import XCTest
@testable import Yggdrasil

final class RemoteSpawnTests: XCTestCase {
    private let host = RemoteHost(id: 1, name: "devbox", sshTarget: "devbox", reposRoot: "/src", createdAt: Date())

    private func spawn(
        command: String = "claude", args: [String] = ["--dangerously-skip-permissions"],
        stored: String? = nil
    ) -> RemoteSpawn {
        RemoteSpawn.make(
            host: host,
            session: OpenSession(
                id: 42, displayName: "t", cwd: "/src/o/r/.worktrees/it's", command: command, args: args
            ),
            storedSessionID: stored, newSessionID: "new-id", colorfgbg: "15;0"
        )
    }

    /// The helper invocation inside the base64 `/bin/sh` wrapper.
    private func remote(_ spawn: RemoteSpawn) -> String {
        SSHCommand.decodePosixRemote(spawn.args.last ?? "") ?? ""
    }

    func testRunsHelperAttachOverInteractiveSSH() {
        let spawn = spawn()
        XCTAssertEqual(spawn.executable, "/usr/bin/ssh")
        XCTAssertEqual(Array(spawn.args.suffix(3).prefix(2)), ["--", "devbox"])
        XCTAssertEqual(remote(spawn), """
        env COLORFGBG='15;0' ~/.yggdrasil/bin/ygg attach 42 '/src/o/r/.worktrees/it'\\''s' \
        --claude-session 'new-id' -- 'claude' '--dangerously-skip-permissions'
        """)
        XCTAssertTrue(spawn.args.contains("-tt"))
    }

    func testNewClaudeTabGetsFreshSessionID() {
        XCTAssertEqual(spawn().claudeSessionID, "new-id")
    }

    func testStoredSessionIDIsReused() {
        let spawn = spawn(stored: "old-id")
        XCTAssertEqual(spawn.claudeSessionID, "old-id")
        XCTAssertTrue(remote(spawn).contains("--claude-session 'old-id'"))
    }

    func testNonClaudeCommandIsNotPinned() {
        let spawn = spawn(command: "/bin/zsh", args: [])
        XCTAssertNil(spawn.claudeSessionID)
        XCTAssertFalse(remote(spawn).contains("--claude-session"))
    }

    func testUserManagedResumeFlagIsNotPinned() {
        XCTAssertNil(spawn(args: ["--continue"]).claudeSessionID)
    }

    func testEmptyCommandAsksHelperForLoginShell() {
        let spawn = spawn(command: "", args: [])
        XCTAssertTrue(remote(spawn).hasSuffix(" --"), remote(spawn))
        XCTAssertNil(spawn.claudeSessionID)
    }

    func testEmptyAgentArgumentsAreKept() {
        let spawn = spawn(args: ["--append-system-prompt", ""])
        XCTAssertTrue(remote(spawn).hasSuffix("-- 'claude' '--append-system-prompt' ''"), remote(spawn))
    }
}
