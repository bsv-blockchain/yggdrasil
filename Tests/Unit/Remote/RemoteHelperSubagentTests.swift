import XCTest
@testable import Yggdrasil

/// `ygg subagents` and `ygg subagent-tail`: a remote tab's subagents, run
/// against the real script with the same scratch HOME and stubs.
extension RemoteHelperTests {
    /// Writes `~/.claude/projects/<dir>/<relative>` with a fixed mtime.
    @discardableResult
    private func writeProjectFile(dir: String, _ relative: String, _ body: String,
                                  mtime: TimeInterval) throws -> String {
        let url = home.appendingPathComponent(".claude/projects/\(dir)/\(relative)")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: mtime)], ofItemAtPath: url.path
        )
        return url.path
    }

    /// The header line keeps "no subagents" apart from an empty reply, which
    /// is what an undecodable one turns into.
    func testSubagentsWithoutAConversationSendsTheHeaderOnly() throws {
        let result = try sh(ygg("subagents -w"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(result.stdout, "subagents\n")
    }

    func testSubagentsListsTheNewestConversationsMetaFiles() throws {
        try writeProjectFile(dir: "-w", "old.jsonl", "o\n", mtime: 1_700_000_000)
        try writeProjectFile(dir: "-w", "old/subagents/agent-stale.meta.json", #"{"x":1}"#, mtime: 1_700_000_000)
        try writeProjectFile(dir: "-w", "new.jsonl", "n\n", mtime: 1_700_000_500)
        try writeProjectFile(
            dir: "-w",
            "new/subagents/agent-a1.meta.json",
            "{\"agentType\":\"Explore\",\n\"finished\":false}",
            mtime: 1_700_000_400
        )
        try writeProjectFile(dir: "-w", "new/subagents/agent-a1.jsonl", "t\n", mtime: 1_700_000_450)
        try writeProjectFile(
            dir: "-w",
            "new/subagents/agent-b2.meta.json",
            #"{"agentType":"Plan"}"#,
            mtime: 1_700_000_400
        )

        let result = try sh(ygg("subagents -w"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let lines = result.stdout.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "subagents new", "names the conversation it read")
        let rows = lines.dropFirst()
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.map(\.first), ["a1", "b2"])
        let first = try XCTUnwrap(rows.first)
        XCTAssertEqual(first[1], "1700000450", "the transcript's mtime")
        XCTAssertNotNil(Int(first[2]), "its creation time")
        XCTAssertEqual(first[3], #"{"agentType":"Explore","finished":false}"#, "on one line")
        XCTAssertEqual(Array(rows[1][1 ... 3]), ["-", "-", #"{"agentType":"Plan"}"#], "no transcript yet")
    }

    func testFinishedSubagentsAreLeftOutOnTheHost() throws {
        // Sessions collect hundreds of finished ones; each would cost a stat.
        try writeProjectFile(dir: "-w", "s.jsonl", "c\n", mtime: 1_700_000_000)
        try writeProjectFile(dir: "-w", "s/subagents/agent-done.meta.json", #"{"finished":true}"#, mtime: 1_700_000_000)
        try writeProjectFile(
            dir: "-w",
            "s/subagents/agent-live.meta.json",
            #"{"finished":false}"#,
            mtime: 1_700_000_000
        )
        let rows = try sh(ygg("subagents -w")).stdout.split(separator: "\n").dropFirst()
        XCTAssertEqual(rows.map { String($0.prefix(4)) }, ["live"])
    }

    func testSubagentTailSendsWholeLines() throws {
        try writeProjectFile(dir: "-w", "s.jsonl", "c\n", mtime: 1_700_000_000)
        try writeProjectFile(dir: "-w", "s/subagents/agent-a1.jsonl", "aaaa\nbbbb\ncccc\n", mtime: 1_700_000_000)
        XCTAssertEqual(try sh(ygg("subagent-tail -w s a1 1000")).stdout, "ok 15\naaaa\nbbbb\ncccc\n")
        XCTAssertEqual(
            try sh(ygg("subagent-tail -w s a1 7")).stdout,
            "ok 15\ncccc\n",
            "the leading fragment is dropped"
        )
        XCTAssertEqual(try sh(ygg("subagent-tail -w s zz 1000")).stdout, "none\n")
        XCTAssertEqual(try sh(ygg("subagent-tail -w other a1 1000")).stdout, "none\n", "another conversation")
    }

    func testSubagentTailSkipsAnUnchangedFile() throws {
        // The view asks every few seconds; an unchanged megabyte needn't cross again.
        try writeProjectFile(dir: "-w", "s.jsonl", "c\n", mtime: 1_700_000_000)
        try writeProjectFile(dir: "-w", "s/subagents/agent-a1.jsonl", "aaaa\n", mtime: 1_700_000_000)
        XCTAssertEqual(try sh(ygg("subagent-tail -w s a1 1000 5")).stdout, "same 5\n")
        XCTAssertEqual(try sh(ygg("subagent-tail -w s a1 1000 4")).stdout, "ok 5\naaaa\n")
    }

    func testSubagentTailRefusesAPathForAnID() throws {
        XCTAssertEqual(try sh(ygg("subagent-tail -w s ../x 1000")).exitCode, 2)
        XCTAssertEqual(try sh(ygg("subagent-tail -w ../s a1 1000")).exitCode, 2)
    }

    // MARK: - Workflow agents

    /// Claude Code's workflows keep each agent under
    /// `<session>/subagents/workflows/<run>/`, with a `journal.jsonl` of
    /// "started" and "result" events; `<session>/../workflows/<run>.json`
    /// only appears when the run ends, and its script is saved as
    /// `workflows/scripts/<name>-<run>.js` from the start.
    private func writeWorkflow(run: String, name: String, journal: [String], finished: Bool = false) throws {
        let dir = "s/subagents/workflows/\(run)"
        try writeProjectFile(dir: "-w", "s.jsonl", "c\n", mtime: 1_700_000_000)
        try writeProjectFile(dir: "-w", "s/workflows/scripts/\(name)-\(run).js", "x", mtime: 1_700_000_000)
        try writeProjectFile(
            dir: "-w",
            "\(dir)/journal.jsonl",
            journal.joined(separator: "\n") + "\n",
            mtime: 1_700_000_000
        )
        for agent in ["a1", "a2"] {
            try writeProjectFile(
                dir: "-w", "\(dir)/agent-\(agent).meta.json",
                #"{"agentType":"workflow-subagent","description":"probe:\#(agent)","workflowPhase":"Probe"}"#,
                mtime: 1_700_000_000
            )
            try writeProjectFile(dir: "-w", "\(dir)/agent-\(agent).jsonl", "t\n", mtime: 1_700_000_300)
        }
        if finished {
            try writeProjectFile(dir: "-w", "s/workflows/\(run).json", #"{"status":"completed"}"#, mtime: 1_700_000_400)
        }
    }

    func testARunningWorkflowsAgentsAreListedWithItsName() throws {
        try writeWorkflow(run: "wf_01-ab", name: "probe-files", journal: [
            #"{"type":"launched"}"#,
            #"{"type":"started","key":"k1","agentId":"a1","label":"probe:a1","phase":"Probe"}"#,
            #"{"type":"started","key":"k2","agentId":"a2","label":"probe:a2","phase":"Probe"}"#,
            #"{"type":"result","key":"k2","agentId":"a2","result":"done"}"#
        ])
        let lines = try sh(ygg("subagents -w")).stdout.split(separator: "\n").map(String.init)
        let workflow = lines.filter { $0.hasPrefix("W\t") }
        XCTAssertEqual(workflow.count, 1, "a2 has its result")
        let fields = workflow[0].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        XCTAssertEqual(Array(fields[0 ... 4]), ["W", "wf_01-ab", "probe-files", "a1", "1700000300"])
        XCTAssertTrue(fields[6].contains(#""description":"probe:a1""#), fields[6])
    }

    func testAFinishedWorkflowListsNothing() throws {
        try writeWorkflow(run: "wf_02-cd", name: "done-run", journal: [
            #"{"type":"started","key":"k1","agentId":"a1","label":"probe:a1","phase":"Probe"}"#
        ], finished: true)
        XCTAssertFalse(try sh(ygg("subagents -w")).stdout.contains("W\t"))
    }

    func testSubagentTailReadsAWorkflowAgent() throws {
        try writeWorkflow(run: "wf_03-ef", name: "x", journal: [])
        XCTAssertEqual(try sh(ygg("subagent-tail -w s wf_03-ef:a1 1000")).stdout, "ok 2\nt\n")
        XCTAssertEqual(try sh(ygg("subagent-tail -w s ../x:a1 1000")).exitCode, 2)
        XCTAssertEqual(try sh(ygg("subagent-tail -w s wf_03-ef:a-1 1000")).exitCode, 2, "agent part")
        XCTAssertEqual(try sh(ygg("subagent-tail -w s wf_03-ef: 1000")).exitCode, 2)
        XCTAssertEqual(try sh(ygg("subagent-tail -w s :a1 1000")).exitCode, 2)
    }

    func testAnAgentIsListedOnceAndOnlyAStartEventStartsIt() throws {
        // One row per agent, as on a local tab: a repeated "started" mustn't
        // list it twice, and a result that mentions "started" isn't a start.
        try writeWorkflow(run: "wf_04-gh", name: "x", journal: [
            #"{"type":"started","key":"k1","agentId":"a1","label":"l","phase":"P"}"#,
            #"{"type":"started","key":"k1","agentId":"a1","label":"l","phase":"P"}"#,
            #"{"type":"started","key":"k2","agentId":"a2","label":"l","phase":"P"}"#,
            #"{"type":"result","key":"k2","agentId":"a2","result":{"type":"started"}}"#
        ])
        let rows = try sh(ygg("subagents -w")).stdout.split(separator: "\n").filter { $0.hasPrefix("W\t") }
        XCTAssertEqual(rows.map { $0.split(separator: "\t")[3] }, ["a1"])
    }

    func testRunsAndNamesThatCantBeSentAreHandled() throws {
        // A run the tail would refuse isn't listed: selecting one of its
        // agents would read as an old helper and reinstall it on every poll.
        // A name that would break the fields falls back to the run id.
        try writeWorkflow(run: "wf_05-ij", name: "bad\tname", journal: [
            #"{"type":"started","key":"k1","agentId":"a1","label":"l","phase":"P"}"#
        ])
        try writeProjectFile(
            dir: "-w", "s/subagents/workflows/wf bad/journal.jsonl",
            #"{"type":"started","key":"k1","agentId":"a1","label":"l","phase":"P"}"# + "\n", mtime: 1_700_000_000
        )
        try writeProjectFile(
            dir: "-w", "s/subagents/workflows/wf bad/agent-a1.meta.json", #"{"agentType":"x"}"#, mtime: 1_700_000_000
        )
        let result = try sh(ygg("subagents -w"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        let rows = result.stdout.split(separator: "\n").filter { $0.hasPrefix("W\t") }
            .map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        XCTAssertEqual(rows.map { Array($0[1 ... 3]) }, [["wf_05-ij", "wf_05-ij", "a1"]])
    }
}
