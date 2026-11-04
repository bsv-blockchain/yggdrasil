import XCTest
@testable import Yggdrasil

/// Reads the newest meaningful record out of the tail of a session transcript.
///
/// Measured against real transcripts, which drive most of these cases:
/// - A Claude file's last line is never a conversation record. Across 81 live
///   files it was always `cost-state` / `system` / `last-prompt` / `atis-latch`,
///   and several of those carry no timestamp. Hence the backward scan.
/// - `stop_reason` lives at `message.stop_reason`, not top level.
/// - Timestamps are RFC3339 *with* fractional seconds.
/// - An "I'm asking you something" turn is `stop_reason: tool_use` carrying an
///   `AskUserQuestion` / `ExitPlanMode` tool call — NOT `end_turn`. The answer
///   arrives later as a `user` record holding a `tool_result`, so the newest
///   record alone distinguishes pending from answered.
final class AgentTranscriptParserTests: XCTestCase {
    private let defaultWhen = "2026-09-16T09:37:10.745Z"

    private func parse(
        _ lines: [String], agent: AgentIdentity = .claude, fromFileStart: Bool = true
    ) -> AgentActivitySample? {
        AgentTranscriptParser.latestActivity(
            inTail: Data(lines.joined(separator: "\n").utf8),
            agent: agent,
            chunkStartsAtFileStart: fromFileStart
        )
    }

    // MARK: - Claude: the record shapes that matter

    private func claudeAssistant(
        stop: String, tool: String? = nil, when: String? = nil, extra: String = ""
    ) -> String {
        let content = tool.map { "[{\"type\":\"tool_use\",\"name\":\"\($0)\"}]" } ?? "[]"
        return """
        {"type":"assistant","timestamp":"\(when ?? defaultWhen)",\(extra)\
        "message":{"stop_reason":"\(stop)","content":\(content)}}
        """
    }

    /// Trailing metadata is the normal state of a live file; the real record is
    /// several lines up.
    func testSkipsTrailingMetadataToReachTheNewestTurn() {
        let sample = parse([
            claudeAssistant(stop: "end_turn"),
            #"{"type":"cost-state","usd":0.12}"#,
            #"{"type":"last-prompt","text":"hi"}"#,
            #"{"type":"atis-latch"}"#
        ])
        XCTAssertEqual(sample?.activity, .turnEnded)
    }

    func testPendingQuestionIsAwaitingAnswer() {
        XCTAssertEqual(
            parse([claudeAssistant(stop: "tool_use", tool: "AskUserQuestion")])?.activity,
            .awaitingAnswer
        )
    }

    func testPendingPlanApprovalIsAwaitingAnswer() {
        XCTAssertEqual(
            parse([claudeAssistant(stop: "tool_use", tool: "ExitPlanMode")])?.activity,
            .awaitingAnswer
        )
    }

    /// Once answered, the newest record is the user's tool_result — so the same
    /// "newest record" rule reports working, with no extra bookkeeping.
    func testAnsweredQuestionIsNoLongerAwaiting() {
        let sample = parse([
            claudeAssistant(stop: "tool_use", tool: "AskUserQuestion"),
            #"{"type":"user","timestamp":"2026-09-16T09:40:00.000Z","message":{"content":[{"type":"tool_result"}]}}"#
        ])
        XCTAssertEqual(sample?.activity, .working)
    }

    /// An ordinary tool call is the agent working, not a demand on the user.
    func testOrdinaryToolUseIsWorking() {
        XCTAssertEqual(
            parse([claudeAssistant(stop: "tool_use", tool: "Bash")])?.activity,
            .working
        )
    }

    func testEndTurnIsTurnEndedNotAwaiting() {
        XCTAssertEqual(parse([claudeAssistant(stop: "end_turn")])?.activity, .turnEnded)
    }

    /// Errors are not a record type — the real signal is this flag on an
    /// otherwise ordinary assistant record.
    func testAPIErrorIsErrored() {
        let sample = parse([
            claudeAssistant(stop: "end_turn", extra: "\"isApiErrorMessage\":true,")
        ])
        XCTAssertEqual(sample?.activity, .errored)
    }

    /// A sub-agent finishing must not make the row look like it's waiting on
    /// the user — the main loop is still going.
    func testSidechainRecordsAreSkipped() {
        let sample = parse([
            claudeAssistant(stop: "tool_use", tool: "Bash"),
            claudeAssistant(stop: "tool_use", tool: "AskUserQuestion", extra: "\"isSidechain\":true,")
        ])
        XCTAssertEqual(sample?.activity, .working)
    }

    func testMetaRecordsAreSkipped() {
        let sample = parse([
            claudeAssistant(stop: "end_turn"),
            claudeAssistant(stop: "tool_use", tool: "Bash", extra: "\"isMeta\":true,")
        ])
        XCTAssertEqual(sample?.activity, .turnEnded)
    }

    // MARK: - Timestamps

    func testParsesFractionalSecondTimestamps() {
        let sample = parse([claudeAssistant(stop: "end_turn", when: "2026-09-16T09:37:10.745Z")])
        // Plain .iso8601 decoding rejects the fractional part outright.
        XCTAssertEqual(sample?.timestamp.timeIntervalSince1970 ?? 0, 1_789_551_430.745, accuracy: 0.001)
    }

    // MARK: - Partial lines

    /// The window starts mid-file, so its first line is a fragment.
    func testLeadingPartialLineIsDroppedWhenNotAtFileStart() {
        let sample = parse(
            ["pe\":\"assistant\",\"message\":{\"stop_reason\":\"end_turn\"}}"],
            fromFileStart: false
        )
        XCTAssertNil(sample)
    }

    func testLeadingLineIsKeptWhenTheWindowCoversTheWholeFile() {
        XCTAssertEqual(parse([claudeAssistant(stop: "end_turn")])?.activity, .turnEnded)
    }

    /// A file being appended to mid-write: the last line is half there.
    func testTrailingPartialLineIsIgnored() {
        let sample = parse([
            claudeAssistant(stop: "end_turn"),
            "{\"type\":\"assist"
        ])
        XCTAssertEqual(sample?.activity, .turnEnded)
    }

    func testMetadataOnlyChunkYieldsNothing() {
        XCTAssertNil(parse([#"{"type":"cost-state"}"#, #"{"type":"atis-latch"}"#]))
    }

    func testEmptyChunkYieldsNothing() {
        XCTAssertNil(parse([]))
    }

    /// A conversation record with no usable timestamp can't be aged, so it is
    /// no better than having found nothing.
    func testRecordWithoutATimestampIsIgnored() {
        XCTAssertNil(parse([#"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#]))
    }

    // MARK: - Codex

    private func codexEvent(_ type: String, when: String? = nil) -> String {
        #"{"type":"event_msg","timestamp":"\#(when ?? defaultWhen)","payload":{"type":"\#(type)"}}"#
    }

    func testCodexTaskCompleteIsTurnEnded() {
        XCTAssertEqual(parse([codexEvent("task_complete")], agent: .codex)?.activity, .turnEnded)
    }

    func testCodexTaskStartedIsWorking() {
        XCTAssertEqual(parse([codexEvent("task_started")], agent: .codex)?.activity, .working)
    }

    func testCodexItemCompletedIsWorking() {
        XCTAssertEqual(parse([codexEvent("item_completed")], agent: .codex)?.activity, .working)
    }

    /// `reason: interrupted` is the user pressing Escape — their own doing, so
    /// it must not come back as something demanding attention.
    func testCodexTurnAbortedIsTurnEnded() {
        XCTAssertEqual(parse([codexEvent("turn_aborted")], agent: .codex)?.activity, .turnEnded)
    }

    /// Bookkeeping events fire constantly and say nothing about the session.
    func testCodexBookkeepingEventsAreSkipped() {
        let sample = parse([
            codexEvent("task_complete"),
            codexEvent("token_count"),
            codexEvent("thread_settings_applied")
        ], agent: .codex)
        XCTAssertEqual(sample?.activity, .turnEnded)
    }

    /// Codex has no blocking-question event at all under
    /// --dangerously-bypass-approvals-and-sandbox; nothing may invent one.
    func testCodexNeverReportsAwaitingAnswer() {
        for event in ["task_started", "task_complete", "turn_aborted", "item_completed", "agent_message"] {
            XCTAssertNotEqual(
                parse([codexEvent(event)], agent: .codex)?.activity, .awaitingAnswer,
                "\(event) must not read as a pending question"
            )
        }
    }

    /// Claude's record shape in a Codex file (or vice versa) must not match.
    func testClaudeRecordsAreIgnoredWhenReadingAsCodex() {
        XCTAssertNil(parse([claudeAssistant(stop: "end_turn")], agent: .codex))
    }
}
