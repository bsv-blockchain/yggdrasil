import XCTest
@testable import Yggdrasil

/// Subagents of a tab on an ssh host: their files are on the host, so the
/// list and the transcript come from `ygg subagents` and `ygg subagent-tail`.
final class RemoteSubagentTests: XCTestCase {
    private let host = RemoteHost(id: 1, name: "devbox", sshTarget: "me@devbox", reposRoot: "/src", createdAt: Date())

    private func ok(_ stdout: String) -> SubprocessResult {
        SubprocessResult(stdout: stdout, stderr: "", exitCode: 0)
    }

    // MARK: - Parsing

    func testParsesTheList() throws {
        let list = try SSHSubagentSource.parseSubagents("""
        subagents s1
        a1\t1700000450\t1700000300\t{"agentType":"Explore","finished":false}
        b2\t-\t-\t{"agentType":"Plan"}
        c3\t1700000460\t0\t{"agentType":"Explore"}

        """)
        XCTAssertEqual(list.conversationID, "s1")
        let entries = list.entries
        XCTAssertEqual(entries.map(\.agentID), ["a1", "b2", "c3"])
        XCTAssertEqual(entries[0].modified, Date(timeIntervalSince1970: 1_700_000_450))
        XCTAssertEqual(entries[0].created, Date(timeIntervalSince1970: 1_700_000_300))
        XCTAssertNil(entries[1].modified, "no transcript yet")
        XCTAssertNil(entries[2].created, "birth time unknown on this filesystem")
        XCTAssertEqual(entries[0].meta, Data(#"{"agentType":"Explore","finished":false}"#.utf8))
    }

    func testAnEmptyOrStrangeReplyIsAnError() throws {
        // "" is what ProcessRunner returns for output that isn't valid UTF-8.
        XCTAssertThrowsError(try SSHSubagentSource.parseSubagents(""))
        XCTAssertThrowsError(try SSHSubagentSource.parseSubagents("usage: ygg …\n"))
        let none = try SSHSubagentSource.parseSubagents("subagents\n")
        XCTAssertNil(none.conversationID)
        XCTAssertEqual(none.entries.count, 0)
    }

    func testParsesATail() throws {
        XCTAssertEqual(try SSHSubagentSource.parseTail("none\n"), SubagentTail.none)
        XCTAssertEqual(try SSHSubagentSource.parseTail("same 12\n"), SubagentTail.unchanged)
        XCTAssertEqual(
            try SSHSubagentSource.parseTail("ok 6\nl1\nl2\n"), SubagentTail.lines(Data("l1\nl2\n".utf8), size: 6)
        )
        XCTAssertThrowsError(try SSHSubagentSource.parseTail(""))
        XCTAssertThrowsError(try SSHSubagentSource.parseTail("ok\nx\n"))
    }

    // MARK: - Commands

    func testAsksTheHelper() async throws {
        let stub = StubSubprocessRunner(responses: [ok("subagents\n"), ok("none\n")])
        let source = SSHSubagentSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        _ = try await source.subagents(projectDirectory: "-src-r")
        _ = try await source.tail(
            projectDirectory: "-src-r", conversationID: "s1", agentID: "a1", maxBytes: 1000, knownSize: 512
        )
        let calls = await stub.recordedCalls()
        XCTAssertEqual(
            SSHCommand.decodePosixRemote(calls[0].arguments.last ?? ""),
            "~/.yggdrasil/bin/ygg subagents '-src-r'"
        )
        XCTAssertEqual(
            SSHCommand.decodePosixRemote(calls[1].arguments.last ?? ""),
            "~/.yggdrasil/bin/ygg subagent-tail '-src-r' 's1' 'a1' 1000 512"
        )
    }

    // MARK: - The same rules as on this Mac

    func testTheHostsListGetsTheLocalRules() async throws {
        let stub = StubSubprocessRunner(responses: [ok("""
        subagents s1
        live\t1700000500\t1700000400\t{"agentType":"Explore","description":"Live","finished":false}
        done\t1700000500\t1700000400\t{"agentType":"Explore","finished":true}
        left\t1699990000\t1699990000\t{"agentType":"Explore","finished":false}

        """)])
        let source = SSHSubagentSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        let found = try await SubagentProbe.unfinished(
            worktreePath: "/src/r", since: Date(timeIntervalSince1970: 1_700_000_100),
            now: Date(timeIntervalSince1970: 1_700_000_600), source: source
        )
        XCTAssertEqual(found.map(\.agentID), ["live"])
        XCTAssertEqual(found.first?.description, "Live")
        XCTAssertEqual(found.first?.conversationID, "s1", "the transcript view asks for this conversation")
    }

    func testOnAHostRecentWorkCountsThoughWrittenBeforeTheAttach() async throws {
        // The Mac's start time is the ssh attach, which a reconnect or a
        // relaunch moves while the claude on the host runs on; and the
        // host's clock isn't the Mac's.
        let stub = StubSubprocessRunner(responses: [ok("""
        subagents s1
        busy\t1700000000\t1699999000\t{"agentType":"Explore","finished":false}

        """)])
        let source = SSHSubagentSource(runner: SSHSubprocessRunner(host: host, transport: stub))
        let found = try await SubagentProbe.unfinished(
            worktreePath: "/src/r", since: Date(timeIntervalSince1970: 1_700_000_500),
            now: Date(timeIntervalSince1970: 1_700_000_600), source: source
        )
        XCTAssertEqual(found.map(\.agentID), ["busy"])
    }
}
