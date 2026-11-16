import XCTest
@testable import Yggdrasil

/// Finding a tab's subagents: Claude Code writes each one's transcript to
/// `<project>/<session-id>/subagents/agent-<id>.jsonl`, with a small
/// `agent-<id>.meta.json` beside it saying what it is and whether it's done.
final class SubagentProbeTests: XCTestCase {
    private let worktree = "/w/repo/.worktrees/feat"
    private var project: String {
        "/h/.claude/projects/\(AgentSessionLocator.encode(cwd: worktree))"
    }

    private let now = Date(timeIntervalSince1970: 1000)

    func testListsTheUnfinishedSubagentsOfTheNewestConversation() {
        // The newest conversation, as the status dot reads it: after /clear
        // the tab's claude writes a new one under the same project.
        let files = StubSubagentFS()
        files.add("\(project)/old.jsonl", "", created: 1, modified: 10)
        files.add("\(project)/new.jsonl", "", created: 2, modified: 20)
        let dir = "\(project)/new/subagents"
        files.add("\(dir)/agent-a1.meta.json", meta(type: "Explore", description: "Find tests", shape: "background"))
        files.add("\(dir)/agent-a1.jsonl", "", created: 10, modified: 50)
        files.add("\(dir)/agent-b2.meta.json", meta(type: "code-reviewer", description: "Review", finished: true))
        files.add("\(dir)/agent-b2.jsonl", "", created: 5, modified: 40)
        files.add("\(project)/old/subagents/agent-c3.meta.json", meta(type: "Explore", description: "Stale"))
        files.add("\(project)/old/subagents/agent-c3.jsonl", "", created: 5, modified: 40)

        let found = probe(files).unfinished(worktreePath: worktree, since: nil, now: now)

        XCTAssertEqual(found, [SubagentInfo(
            agentID: "a1", agentType: "Explore", description: "Find tests", spawnDepth: 1,
            background: true, lastWrite: Date(timeIntervalSince1970: 50), transcriptPath: "\(dir)/agent-a1.jsonl"
        )])
    }

    func testOnlyThoseWrittenSinceTheAgentStarted() {
        // A claude that was killed never marks its subagents finished; once
        // the tab's agent is started again they're leftovers.
        let files = conversation()
        let dir = "\(project)/s/subagents"
        files.add("\(dir)/agent-left.meta.json", meta(type: "Explore", description: "Leftover"))
        files.add("\(dir)/agent-left.jsonl", "", created: 40, modified: 50)
        files.add("\(dir)/agent-live.meta.json", meta(type: "Explore", description: "Live"))
        files.add("\(dir)/agent-live.jsonl", "", created: 110, modified: 150)

        let found = probe(files).unfinished(worktreePath: worktree, since: Date(timeIntervalSince1970: 100), now: now)

        XCTAssertEqual(found.map(\.agentID), ["live"])
    }

    func testWithoutAFinishedFieldOnlyRecentWorkCounts() {
        // Claude Code before late October 2026 never wrote `finished`.
        let files = conversation()
        let dir = "\(project)/s/subagents"
        files.add("\(dir)/agent-recent.meta.json", meta(type: "Explore", description: "Recent", finished: nil))
        files.add("\(dir)/agent-recent.jsonl", "", created: 900, modified: 950)
        files.add("\(dir)/agent-done.meta.json", meta(type: "Explore", description: "Done long ago", finished: nil))
        files.add("\(dir)/agent-done.jsonl", "", created: 100, modified: 200)

        let found = probe(files).unfinished(worktreePath: worktree, since: nil, now: now)

        XCTAssertEqual(found.map(\.agentID), ["recent"])
    }

    func testOrderIsWhenEachStartedAndJunkIsSkipped() {
        let files = conversation()
        let dir = "\(project)/s/subagents"
        files.add("\(dir)/agent-late.meta.json", meta(type: "Explore", description: "Second", depth: 2))
        files.add("\(dir)/agent-late.jsonl", "", created: 30, modified: 31)
        files.add("\(dir)/agent-early.meta.json", meta(type: "Explore", description: "First"))
        files.add("\(dir)/agent-early.jsonl", "", created: 20, modified: 90)
        files.add("\(dir)/agent-bad.meta.json", "{not json")
        files.add("\(dir)/notes.txt", "x")

        let found = probe(files).unfinished(worktreePath: worktree, since: nil, now: now)

        XCTAssertEqual(found.map(\.agentID), ["early", "late"])
        XCTAssertEqual(found.last?.spawnDepth, 2)
    }

    func testARunningWorkflowsAgentsAreListedFromItsJournal() {
        // Workflow agents' meta files never say "finished"; the run's journal
        // does, and the run's own file only appears when it ends.
        let files = conversation()
        let run = "\(project)/s/subagents/workflows/wf_01-ab"
        files.add("\(project)/s/workflows/scripts/review-x-wf_01-ab.js", "x")
        files.add("\(run)/journal.jsonl", """
        {"type":"launched"}
        {"type":"started","key":"k1","agentId":"a1","label":"review:a","phase":"Review"}
        {"type":"started","key":"k2","agentId":"a2","label":"review:b","phase":"Review"}
        {"type":"result","key":"k2","agentId":"a2","result":"done"}
        """)
        for agent in ["a1", "a2"] {
            files.add("\(run)/agent-\(agent).meta.json",
                      #"{"agentType":"code-reviewer","description":"review:\#(agent)","workflowPhase":"Review"}"#)
            // Written well outside the window for meta files without "finished".
            files.add("\(run)/agent-\(agent).jsonl", "", created: 10, modified: 20)
        }
        files.add("\(project)/s/workflows/wf_02-cd.json", #"{"status":"completed"}"#)
        files.add("\(project)/s/subagents/workflows/wf_02-cd/journal.jsonl",
                  #"{"type":"started","key":"k","agentId":"z9","label":"l","phase":"P"}"#)
        files.add("\(project)/s/subagents/workflows/wf_02-cd/agent-z9.meta.json", #"{"agentType":"x"}"#)

        let found = probe(files).unfinished(worktreePath: worktree, since: nil, now: now)

        XCTAssertEqual(found.map(\.agentID), ["wf_01-ab:a1"])
        XCTAssertEqual(found.first?.workflow, SubagentWorkflow(runID: "wf_01-ab", name: "review-x"))
        XCTAssertEqual(found.first?.phase, "Review")
        XCTAssertEqual(found.first?.transcriptPath, "\(run)/agent-a1.jsonl")
    }

    func testAWorkflowAgentWithoutRecentWorkIsLeftOut() {
        // A stopped or crashed run may never get its <run>.json. Its agents
        // fade once their transcripts go quiet, and one without a transcript
        // doesn't show at all.
        let meta = Data(#"{"agentType":"workflow-subagent"}"#.utf8)
        let workflow = SubagentWorkflow(runID: "wf_01-ab", name: "x")
        func entry(_ agent: String, modified: Date?) -> SubagentMetaEntry {
            SubagentMetaEntry(
                agentID: "wf_01-ab:\(agent)", meta: meta, modified: modified, created: nil,
                transcriptPath: "/p", workflow: workflow
            )
        }
        let found = SubagentProbe.select([
            entry("live", modified: now.addingTimeInterval(-60)),
            entry("quiet", modified: now.addingTimeInterval(-SubagentProbe.workflowActivityWindow - 1)),
            entry("none", modified: nil)
        ], since: nil, now: now)
        XCTAssertEqual(found.map(\.agentID), ["wf_01-ab:live"])
    }

    func testWorkflowRunsAndAgentsTheHelperWouldRefuseAreSkipped() {
        // The same rules as the host's helper, so a local tab and a host tab
        // list the same agents and every listed one can be opened.
        let files = conversation()
        let good = "\(project)/s/subagents/workflows/wf_01-ab"
        let bad = "\(project)/s/subagents/workflows/wf bad"
        files.add("\(good)/journal.jsonl", """
        {"type":"started","key":"k1","agentId":"a-2","label":"l","phase":"P"}
        {"type":"started","key":"k2","agentId":"a3","label":"l","phase":"P"}
        """)
        files.add("\(bad)/journal.jsonl", #"{"type":"started","key":"k","agentId":"a1","label":"l","phase":"P"}"#)
        for path in ["\(good)/agent-a-2", "\(good)/agent-a3", "\(bad)/agent-a1"] {
            files.add("\(path).meta.json", #"{"agentType":"x"}"#)
            files.add("\(path).jsonl", "", created: 10, modified: 20)
        }
        // Two scripts for the run: the helper's glob takes the last in order.
        files.add("\(project)/s/workflows/scripts/alpha-wf_01-ab.js", "x")
        files.add("\(project)/s/workflows/scripts/beta-wf_01-ab.js", "x")

        let found = probe(files).unfinished(worktreePath: worktree, since: nil, now: now)

        XCTAssertEqual(found.map(\.agentID), ["wf_01-ab:a3"])
        XCTAssertEqual(found.first?.workflow?.name, "beta")
    }

    func testAWorkflowAgentsTranscriptPath() {
        let files = conversation()
        XCTAssertEqual(
            probe(files).transcriptPath(worktreePath: worktree, agentID: "wf_01-ab:a1"),
            "\(project)/s/subagents/workflows/wf_01-ab/agent-a1.jsonl"
        )
    }

    func testNoConversationNoSubagents() {
        XCTAssertEqual(probe(StubSubagentFS()).unfinished(worktreePath: worktree, since: nil, now: now), [])
    }

    // MARK: - Helpers

    /// A project with one conversation, `s`.
    private func conversation() -> StubSubagentFS {
        let files = StubSubagentFS()
        files.add("\(project)/s.jsonl", "", created: 1, modified: 10)
        return files
    }

    private func probe(_ files: StubSubagentFS) -> SubagentProbe {
        SubagentProbe(fileSystem: files, home: "/h")
    }

    private func meta(
        type: String, description: String, depth: Int = 1, shape: String = "foreground", finished: Bool? = false
    ) -> String {
        let finishedField = finished.map { #","finished":\#($0)"# } ?? ""
        return """
        {"agentType":"\(type)","isBuiltIn":false,"description":"\(description)","toolUseId":"toolu_1",\
        "spawnDepth":\(depth),"requestShape":"\(shape)"\(finishedField)}
        """
    }
}

/// Files keyed by full path; a directory listing is every name directly under it.
private final class StubSubagentFS: SubagentFileSystem, @unchecked Sendable {
    private struct File {
        let data: Data
        let created: Date
        let modified: Date
    }

    private var files: [String: File] = [:]

    func add(_ path: String, _ text: String, created: TimeInterval = 0, modified: TimeInterval = 0) {
        files[path] = File(
            data: Data(text.utf8),
            created: Date(timeIntervalSince1970: created),
            modified: Date(timeIntervalSince1970: modified)
        )
    }

    /// Files and folders directly under `path`, as a directory listing has them.
    func fileNames(inDirectory path: String) -> [String] {
        Array(Set(files.keys.compactMap { key in
            guard key.hasPrefix(path + "/") else { return nil }
            return key.dropFirst(path.count + 1).split(separator: "/").first.map(String.init)
        }))
    }

    func contents(atPath path: String) -> Data? {
        files[path]?.data
    }

    func dates(atPath path: String) -> (created: Date, modified: Date)? {
        files[path].map { ($0.created, $0.modified) }
    }

    func transcripts(inDirectory path: String) -> [TranscriptFile] {
        fileNames(inDirectory: path).filter { $0.hasSuffix(".jsonl") }.compactMap { name in
            let full = "\(path)/\(name)"
            guard let file = files[full] else { return nil }
            return TranscriptFile(path: full, modified: file.modified, size: UInt64(file.data.count))
        }
    }

    func readTail(path: String, maxBytes: Int) throws -> (data: Data, startsAtFileStart: Bool) {
        let data = files[path]?.data ?? Data()
        return data.count <= maxBytes ? (data, true) : (data.suffix(maxBytes), false)
    }
}
