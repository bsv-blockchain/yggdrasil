import XCTest
@testable import Yggdrasil

/// A subagent's transcript, turned into what the read-only view shows. The
/// line shapes match real Claude Code subagent transcripts: the prompt is a
/// user message with string content; tool calls and results are content
/// blocks; `thinking`, `api-request*` and `attachment` records are bookkeeping.
final class SubagentTranscriptParserTests: XCTestCase {
    func testPromptTextToolCallsAndResults() {
        let entries = parse([
            #"{"type":"user","isSidechain":true,"message":{"role":"user","content":"List the tests"}}"#,
            #"{"type":"api-request","requestId":"r1"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm","signature":"s"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls Tests\nwc -l","description":"List"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"a\nb\nc","is_error":false}]}}"#,
            #"{"type":"attachment","attachment":{}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Two files."}]}}"#
        ])
        XCTAssertEqual(entries, [
            .prompt("List the tests"),
            .text("Looking."),
            .toolCall(id: "t1", name: "Bash", summary: "ls Tests wc -l"),
            .toolResult(toolUseID: "t1", preview: "a\nb\nc", isError: false),
            .text("Two files.")
        ])
    }

    func testRemindersClaudeCodeInjectsAreLeftOut() {
        // Seen in real subagent transcripts, as a second user message right
        // after the task.
        let entries = parse([
            #"{"type":"user","message":{"content":"Find the tests"}}"#,
            #"{"type":"user","message":{"content":"<system-reminder>\nYour final report is delivered through …\n</system-reminder>"}}"#,
            #"{"type":"user","message":{"content":[{"type":"text","text":"<system-reminder>x</system-reminder>"},{"tool_use_id":"t1","type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"user","message":{"content":"[SYSTEM NOTIFICATION - NOT USER INPUT]\nA background task finished."}}"#
        ])
        XCTAssertEqual(entries, [
            .prompt("Find the tests"),
            .toolResult(toolUseID: "t1", preview: "ok", isError: false)
        ])
    }

    func testToolCallSummaryPicksTheTellingField() {
        let entries = parse([
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/x/y.swift","limit":20}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Other","input":{"n":1}}]}}"#
        ])
        XCTAssertEqual(entries, [
            .toolCall(id: "t1", name: "Read", summary: "/x/y.swift"),
            .toolCall(id: "t2", name: "Other", summary: #"{"n":1}"#)
        ])
    }

    func testResultsAreShortenedAndErrorsMarked() {
        let long = (1 ... 20).map { "line \($0)" }.joined(separator: "\\n")
        let entries = parse([
            #"{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":[{"type":"text","text":"\#(long)"}],"is_error":true}]}}"#
        ])
        guard case let .toolResult(_, preview, isError)? = entries.first else { return XCTFail("\(entries)") }
        XCTAssertTrue(isError)
        XCTAssertEqual(preview.split(separator: "\n").count, SubagentTranscriptParser.resultLines + 1)
        XCTAssertTrue(preview.hasSuffix("… 14 more lines"), preview)
    }

    func testAVeryLongResultLineIsCut() {
        let wide = String(repeating: "x", count: 5000)
        let entries = parse([
            #"{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"\#(wide)"}]}}"#
        ])
        guard case let .toolResult(_, preview, _)? = entries.first else { return XCTFail("\(entries)") }
        XCTAssertEqual(preview.count, SubagentTranscriptParser.resultLineLength + 1, "the cut, plus …")
    }

    func testAChunkFromMidFileDropsItsFirstLine() {
        let text = #"ragment"}"# + "\n"
            + #"{"type":"user","message":{"content":"[Request interrupted by user]"}}"# + "\n"
            + #"{"type":"assistant","message":{"content":[{"type":"text","text":"Done."}]}}"#
        let entries = SubagentTranscriptParser.entries(inTail: Data(text.utf8), startsAtFileStart: false)
        XCTAssertEqual(entries, [.prompt("[Request interrupted by user]"), .text("Done.")])
    }

    private func parse(_ lines: [String]) -> [SubagentEntry] {
        SubagentTranscriptParser.entries(inTail: Data(lines.joined(separator: "\n").utf8), startsAtFileStart: true)
    }
}
