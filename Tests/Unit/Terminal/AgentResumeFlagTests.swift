import XCTest
@testable import Yggdrasil

/// Verifies the `--continue` injection logic that lets Claude pick up its
/// previous in-cwd conversation on app relaunch. Uses injected file-system
/// probes so the test doesn't touch ~/.claude/projects.
final class AgentResumeFlagTests: XCTestCase {
    /// Helper that simulates the filesystem state at `~/.claude/projects/<enc>/`.
    private func makeProbes(hasConversation: Bool) -> (
        fileExists: (String) -> Bool,
        directoryContents: (String) -> [String]?
    ) {
        let exists: (String) -> Bool = { path in
            hasConversation && path.contains(".claude/projects/")
        }
        let contents: (String) -> [String]? = { path in
            guard hasConversation, path.contains(".claude/projects/") else { return nil }
            return ["abc-123.jsonl", "metadata.json"]
        }
        return (exists, contents)
    }

    func test_noConversationHistory_returnsArgsUnchanged() {
        let probes = makeProbes(hasConversation: false)
        let out = AgentTerminalSurface.applyResumeFlag(
            command: "claude", args: ["--dangerously-skip-permissions"],
            cwd: "/tmp/foo", fileExists: probes.fileExists,
            directoryContents: probes.directoryContents
        )
        XCTAssertEqual(out, ["--dangerously-skip-permissions"])
    }

    func test_conversationHistoryExists_appendsContinue() {
        let probes = makeProbes(hasConversation: true)
        let out = AgentTerminalSurface.applyResumeFlag(
            command: "claude", args: ["--dangerously-skip-permissions"],
            cwd: "/Users/me/checkout/.worktrees/pr-643",
            fileExists: probes.fileExists,
            directoryContents: probes.directoryContents
        )
        XCTAssertEqual(out, ["--dangerously-skip-permissions", "--continue"])
    }

    func test_nonClaudeCommand_neverGetsFlag() {
        let probes = makeProbes(hasConversation: true)
        let out = AgentTerminalSurface.applyResumeFlag(
            command: "codex", args: ["-m", "gpt-4"], cwd: "/tmp/foo",
            fileExists: probes.fileExists,
            directoryContents: probes.directoryContents
        )
        XCTAssertEqual(out, ["-m", "gpt-4"])
    }

    func test_flagAlreadyPresent_isIdempotent() {
        let probes = makeProbes(hasConversation: true)
        for existing in ["--continue", "-c", "--resume"] {
            let out = AgentTerminalSurface.applyResumeFlag(
                command: "claude", args: [existing], cwd: "/tmp/foo",
                fileExists: probes.fileExists,
                directoryContents: probes.directoryContents
            )
            XCTAssertEqual(out, [existing], "Should not double-add for \(existing)")
        }
    }

    func test_claudeWithFullPath_stillDetected() {
        let probes = makeProbes(hasConversation: true)
        let out = AgentTerminalSurface.applyResumeFlag(
            command: "/Users/me/.claude/local/bin/claude", args: [],
            cwd: "/tmp/foo",
            fileExists: probes.fileExists,
            directoryContents: probes.directoryContents
        )
        XCTAssertEqual(out, ["--continue"])
    }

    func test_directoryExistsButNoJsonl_doesNotResume() {
        let exists: (String) -> Bool = { _ in true }
        let contents: (String) -> [String]? = { _ in ["metadata.json"] }
        let out = AgentTerminalSurface.applyResumeFlag(
            command: "claude", args: [], cwd: "/tmp/foo",
            fileExists: exists, directoryContents: contents
        )
        XCTAssertEqual(out, [])
    }
}
