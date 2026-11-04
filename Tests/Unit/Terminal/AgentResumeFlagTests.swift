import XCTest
@testable import Yggdrasil

/// Verifies how resume flags are chosen for Claude: an app-owned session id
/// (`--session-id` on first spawn, `--resume <id>` once its transcript exists),
/// with the legacy `--continue` path kept for tabs that predate stored ids.
/// Uses an injected directory listing so the test doesn't touch ~/.claude/projects.
final class AgentResumeFlagTests: XCTestCase {
    private let newID = "11111111-2222-3333-4444-555555555555"
    private let storedID = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private let home = "/Users/me"

    /// Simulates `~/.claude/projects/` as `[projectDirName: [files]]`, and the
    /// tab's `session_state` row as `stored`.
    private func resolve(
        command: String = "claude",
        args: [String] = ["--dangerously-skip-permissions"],
        cwd: String = "/tmp/foo",
        stored: AgentTerminalSurface.StoredSession = .noRow,
        projects: [String: [String]] = [:]
    ) -> AgentTerminalSurface.ResumePlan {
        let root = "\(home)/.claude/projects"
        return AgentTerminalSurface.resolveResume(
            command: command, args: args, cwd: cwd,
            stored: stored, newSessionID: newID, home: home,
            fileExists: { path in
                let parts = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
                return parts.count == 2 && (projects[parts[0]]?.contains(parts[1]) ?? false)
            },
            directoryContents: { path in
                if path == root { return Array(projects.keys) }
                guard path.hasPrefix(root + "/") else { return nil }
                return projects[String(path.dropFirst(root.count + 1))]
            }
        )
    }

    func test_newTab_noHistory_startsNewPinnedSession() {
        let plan = resolve()
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--session-id", newID])
        XCTAssertEqual(plan.sessionID, newID)
    }

    func test_legacyTab_withHistory_keepsContinue() {
        let plan = resolve(
            cwd: "/Users/me/checkout/.worktrees/pr_643", stored: .unpinned,
            projects: ["-Users-me-checkout--worktrees-pr-643": ["abc-123.jsonl"]]
        )
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--continue"])
        XCTAssertNil(plan.sessionID)
    }

    func test_legacyTab_directoryWithoutJsonl_startsNewPinnedSession() {
        let plan = resolve(args: [], stored: .unpinned, projects: ["-tmp-foo": ["metadata.json"]])
        XCTAssertEqual(plan.args, ["--session-id", newID])
        XCTAssertEqual(plan.sessionID, newID)
    }

    func test_storedID_transcriptExists_resumesThatSession() {
        let plan = resolve(stored: .pinned(storedID), projects: ["-tmp-foo": ["\(storedID).jsonl", "other.jsonl"]])
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--resume", storedID])
        XCTAssertEqual(plan.sessionID, storedID)
    }

    func test_storedID_noTranscriptYet_reusesIDWithSessionIDFlag() {
        // Claude only writes the transcript after the first exchange; resuming
        // a never-used id would fail, so pin the same id again instead.
        let plan = resolve(stored: .pinned(storedID), projects: ["-tmp-foo": ["other.jsonl"]])
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--session-id", storedID])
        XCTAssertEqual(plan.sessionID, storedID)
    }

    func test_nonClaudeCommand_neverGetsFlag() {
        let plan = resolve(command: "codex", args: ["-m", "gpt-4"], stored: .pinned(storedID))
        XCTAssertEqual(plan.args, ["-m", "gpt-4"])
        XCTAssertNil(plan.sessionID)
    }

    func test_flagAlreadyPresent_isLeftAlone() {
        for existing in [
            "--continue", "-c", "--resume", "-r", "--session-id",
            "--resume=x", "--session-id=x", "--fork-session"
        ] {
            let plan = resolve(args: [existing], stored: .pinned(storedID))
            XCTAssertEqual(plan.args, [existing], "Should not add a flag next to \(existing)")
            XCTAssertNil(plan.sessionID, "User-managed session for \(existing)")
        }
    }

    func test_claudeWithFullPath_stillDetected() {
        let plan = resolve(
            command: "/Users/me/.claude/local/bin/claude", args: [], stored: .unpinned,
            projects: ["-tmp-foo": ["x.jsonl"]]
        )
        XCTAssertEqual(plan.args, ["--continue"])
    }

    func test_pinnedTranscriptInAnotherProjectDir_resumes() {
        // --resume searches every project dir, so a transcript under a different
        // encoding (moved worktree, long-path hash) still counts; passing
        // --session-id again would exit 1 with "already in use".
        let plan = resolve(cwd: "/tmp/fix_foo", stored: .pinned(storedID), projects: [
            "-tmp-fix-foo-a1b2c3": ["\(storedID).jsonl"]
        ])
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--resume", storedID])
    }

    func test_newTab_onWorktreeWithOtherConversations_isPinnedNotContinued() {
        // No session_state row → a new tab, even if claude was used here before.
        let plan = resolve(projects: ["-tmp-foo": ["someone-else.jsonl"]])
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--session-id", newID])
        XCTAssertEqual(plan.sessionID, newID)
    }

    func test_unreadableSessionRow_neverMintsANewID() {
        // A DB read error must not replace an existing pin with a fresh id.
        let plan = resolve(stored: .unknown, projects: ["-tmp-foo": ["x.jsonl"]])
        XCTAssertEqual(plan.args, ["--dangerously-skip-permissions", "--continue"])
        XCTAssertNil(plan.sessionID)
    }

    func test_claudeWrapperBinaries_areNotPinned() {
        // Wrappers like claude-squad don't accept claude's session flags.
        for wrapper in ["claude-squad", "/usr/local/bin/claudebox"] {
            let plan = resolve(command: wrapper, args: [])
            XCTAssertEqual(plan.args, [], wrapper)
            XCTAssertNil(plan.sessionID, wrapper)
        }
    }

    func test_pinnedTranscriptInOwnProjectDir_skipsFullScan() {
        var listed: [String] = []
        let plan = AgentTerminalSurface.resolveResume(
            command: "claude", args: [], cwd: "/tmp/foo",
            stored: .pinned(storedID), newSessionID: newID, home: home,
            fileExists: { $0 == "\(self.home)/.claude/projects/-tmp-foo/\(self.storedID).jsonl" },
            directoryContents: { listed.append($0)
                return nil
            }
        )
        XCTAssertEqual(plan.args, ["--resume", storedID])
        XCTAssertEqual(listed, [], "the cwd's own project dir should be checked directly")
    }
}
