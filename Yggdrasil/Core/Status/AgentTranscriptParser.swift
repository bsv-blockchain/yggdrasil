import Foundation

/// What the newest meaningful record in a session transcript says the agent is
/// doing. Deliberately coarse — the sidebar only needs to know whether the
/// session wants the user.
enum AgentActivity: Equatable {
    /// The agent asked an explicit question and is blocked until it's answered.
    /// The only state that earns an amber pill.
    case awaitingAnswer
    /// The API returned an error the user has to deal with.
    case errored
    /// The agent is mid-task.
    case working
    /// The turn finished normally. Resting state, not a demand: 21 of 27 live
    /// tabs sit here, so treating it as "needs you" would make the filter
    /// match nearly everything.
    case turnEnded
}

struct AgentActivitySample: Equatable {
    let activity: AgentActivity
    let timestamp: Date
}

/// Reads the tail of an agent's session transcript.
///
/// Pure: it is handed a chunk of bytes and never touches the filesystem, so
/// every record shape below is unit-tested against fixtures copied from real
/// transcripts.
enum AgentTranscriptParser {
    /// Claude tools that block until the user answers. A turn carrying one of
    /// these has `stop_reason: tool_use` — the same stop reason as any other
    /// tool call — so the tool name is the only thing that distinguishes
    /// "asking you something" from "running a command".
    static let blockingTools: Set<String> = ["AskUserQuestion", "ExitPlanMode"]

    /// Scan `chunk` backwards and return the newest record that says something.
    ///
    /// Backwards because a live transcript's last line is never a conversation
    /// record: across 81 real Claude files it was always bookkeeping
    /// (`cost-state`, `last-prompt`, `atis-latch`, `system`), much of it with no
    /// timestamp at all. Reading "the last line" would report nothing, forever.
    ///
    /// `chunkStartsAtFileStart` false means the window begins mid-file, so its
    /// first line is a fragment and is dropped.
    static func latestActivity(
        inTail chunk: Data,
        agent: AgentIdentity,
        chunkStartsAtFileStart: Bool
    ) -> AgentActivitySample? {
        var lines = chunk.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !chunkStartsAtFileStart, !lines.isEmpty {
            lines.removeFirst()
        }
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            // A half-written trailing line simply fails to decode and the scan
            // carries on to the previous one; no special-casing needed.
            guard let sample = decode(Data(line), agent: agent) else { continue }
            return sample
        }
        return nil
    }

    // MARK: - Record decoding

    private static func decode(_ line: Data, agent: AgentIdentity) -> AgentActivitySample? {
        guard let raw = try? JSONDecoder().decode(RawRecord.self, from: line),
              let when = timestamp(raw.timestamp)
        else {
            return nil
        }
        let activity: AgentActivity? = switch agent {
        case .codex: codexActivity(raw)
        default: claudeActivity(raw)
        }
        return activity.map { AgentActivitySample(activity: $0, timestamp: when) }
    }

    private static func claudeActivity(_ raw: RawRecord) -> AgentActivity? {
        // A sub-agent's turn is not the main loop's: its `AskUserQuestion`
        // would otherwise flip the row to "waiting on you" while the session
        // carries on working. `isMeta` marks system-injected turns.
        guard raw.isSidechain != true, raw.isMeta != true else { return nil }
        switch raw.type {
        case "assistant":
            if raw.isApiErrorMessage == true { return .errored }
            if raw.message?.stopReason == "end_turn" { return .turnEnded }
            let tools = (raw.message?.content ?? [])
                .filter { $0.type == "tool_use" }
                .compactMap(\.name)
            if tools.contains(where: blockingTools.contains) { return .awaitingAnswer }
            return .working
        case "user":
            // Includes the tool_result answering a question, which is what
            // makes an answered question stop reading as pending.
            return .working
        default:
            return nil
        }
    }

    private static func codexActivity(_ raw: RawRecord) -> AgentActivity? {
        guard raw.type == "event_msg", let event = raw.payload?.type else { return nil }
        switch event {
        case "task_complete":
            return .turnEnded
        case "turn_aborted":
            // Always `reason: interrupted` in practice — the user pressed
            // Escape. Their own doing, so not something to flag back at them.
            return .turnEnded
        case "task_started", "item_completed", "agent_message", "user_message":
            return .working
        default:
            // token_count, thread_settings_applied and friends fire constantly
            // and say nothing about what the session is doing.
            return nil
        }
    }

    // MARK: - Timestamps

    /// Transcripts use RFC3339 with fractional seconds, which
    /// `.iso8601` decoding rejects outright.
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let formatterNoFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func timestamp(_ value: String?) -> Date? {
        guard let value else { return nil }
        return formatter.date(from: value) ?? formatterNoFraction.date(from: value)
    }
}

/// Only the fields that matter. `message.content` is declared loosely
/// because a `user` record's content is sometimes a string and sometimes an
/// array — decoding just the pieces we read keeps that from throwing.
private struct RawRecord: Decodable {
    struct ContentBlock: Decodable {
        let type: String?
        let name: String?
    }

    struct Message: Decodable {
        let stopReason: String?
        let content: [ContentBlock]?

        enum CodingKeys: String, CodingKey {
            case stopReason = "stop_reason"
            case content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
            content = try? container.decodeIfPresent([ContentBlock].self, forKey: .content)
        }
    }

    struct Payload: Decodable {
        let type: String?
    }

    let type: String?
    let timestamp: String?
    let message: Message?
    let payload: Payload?
    let isSidechain: Bool?
    let isMeta: Bool?
    let isApiErrorMessage: Bool?
}
