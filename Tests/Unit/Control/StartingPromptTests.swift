import XCTest
@testable import Yggdrasil

/// A tab opened with a prompt starts its new conversation with it, on this
/// Mac and on a host. A resumed conversation never gets it again.
final class StartingPromptTests: XCTestCase {
    func testPromptStartsOnlyANewConversation() {
        let fresh = AgentTerminalSurface.ResumePlan(args: ["--x", "--session-id", "n"], sessionID: "n")
        XCTAssertTrue(AgentTerminalSurface.takesPrompt(fresh, newSessionID: "n"))
        let resumed = AgentTerminalSurface.ResumePlan(args: ["--x", "--resume", "old"], sessionID: "old")
        XCTAssertFalse(AgentTerminalSurface.takesPrompt(resumed, newSessionID: "n"))
        let unpinned = AgentTerminalSurface.ResumePlan(args: ["--x"], sessionID: nil)
        XCTAssertFalse(AgentTerminalSurface.takesPrompt(unpinned, newSessionID: "n"))
    }

    func testThePromptReachesTheAgentThroughItsEnvironmentNotTheShell() {
        // The login shell may be fish or tcsh, which quote differently; the
        // text itself never enters the command it parses. After `--`, so a
        // variadic profile option can't take it as its value.
        let payload = AgentTerminalSurface.payload(
            colorfgbg: "15;0",
            command: "claude",
            args: ["--x"],
            withPrompt: true
        )
        XCTAssertEqual(payload, "export COLORFGBG='15;0'; exec 'claude' '--x' -- \"$YGG_PROMPT\"")
        XCTAssertEqual(
            AgentTerminalSurface.payload(colorfgbg: "15;0", command: "claude", args: ["--x"], withPrompt: false),
            "export COLORFGBG='15;0'; exec 'claude' '--x'"
        )
    }

    func testRemotePromptGoesToTheHelper() {
        let spawn = RemoteSpawn.make(
            host: RemoteHost(id: 1, name: "devbox", sshTarget: "devbox", reposRoot: "/src", createdAt: Date()),
            session: OpenSession(
                id: 42, displayName: "t", cwd: "/src/x", command: "claude", args: [], initialPrompt: "it's broken"
            ),
            storedSessionID: nil, newSessionID: "new-id", colorfgbg: "15;0"
        )
        let remote = SSHCommand.decodePosixRemote(spawn.args.last ?? "") ?? ""
        XCTAssertTrue(
            remote.hasSuffix("--claude-session 'new-id' --prompt 'it'\\''s broken' -- 'claude'"), remote
        )
    }
}
