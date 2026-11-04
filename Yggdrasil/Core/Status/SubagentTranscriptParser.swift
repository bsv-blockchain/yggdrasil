import Foundation

/// One step of a subagent's work, as the transcript view shows it.
enum SubagentEntry: Equatable {
    /// A user message: the task it was given, or a later interruption.
    case prompt(String)
    case text(String)
    /// `summary` is the input's telling field (a command, a path), on one line.
    case toolCall(id: String, name: String, summary: String)
    case toolResult(toolUseID: String, preview: String, isError: Bool)
}

/// Turns a subagent's transcript into `SubagentEntry`s. The format is Claude
/// Code's own and undocumented, so anything unrecognised is skipped rather
/// than failing the whole view: `thinking` blocks, `api-request*` and
/// `attachment` records, and lines that don't parse.
enum SubagentTranscriptParser {
    /// Lines of a tool result shown before "… N more lines".
    static let resultLines = 6
    /// Characters of one result line shown; minified output can be one huge line.
    static let resultLineLength = 300
    private static let summaryLength = 160
    /// Input fields that say what a call does, most telling first.
    private static let summaryKeys = [
        "command",
        "file_path",
        "path",
        "pattern",
        "url",
        "query",
        "description",
        "prompt"
    ]

    /// `startsAtFileStart` false means the chunk begins mid-file, so its
    /// first line is a fragment and is dropped.
    static func entries(inTail data: Data, startsAtFileStart: Bool) -> [SubagentEntry] {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !startsAtFileStart, !lines.isEmpty { lines.removeFirst() }
        return lines.flatMap { line -> [SubagentEntry] in
            guard let record = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = record["type"] as? String, type == "user" || type == "assistant",
                  let message = record["message"] as? [String: Any]
            else { return [] }
            if let text = message["content"] as? String {
                return type == "user" ? nonEmpty(text).map { [.prompt($0)] } ?? [] : []
            }
            guard let blocks = message["content"] as? [[String: Any]] else { return [] }
            return blocks.compactMap(entry)
        }
    }

    private static func entry(_ block: [String: Any]) -> SubagentEntry? {
        switch block["type"] as? String {
        case "text":
            nonEmpty(block["text"] as? String ?? "").map(SubagentEntry.text)
        case "tool_use":
            .toolCall(
                id: block["id"] as? String ?? "",
                name: block["name"] as? String ?? "tool",
                summary: summary(of: block["input"])
            )
        case "tool_result":
            .toolResult(
                toolUseID: block["tool_use_id"] as? String ?? "",
                preview: preview(of: block["content"]),
                isError: block["is_error"] as? Bool ?? false
            )
        default:
            nil
        }
    }

    private static func summary(of input: Any?) -> String {
        let dictionary = input as? [String: Any] ?? [:]
        let raw = summaryKeys.lazy.compactMap { dictionary[$0] as? String }.first
            ?? (try? JSONSerialization.data(
                withJSONObject: dictionary,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ))
            .flatMap { String(bytes: $0, encoding: .utf8) }
            ?? ""
        let oneLine = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return oneLine.count > summaryLength ? String(oneLine.prefix(summaryLength)) + "…" : oneLine
    }

    private static func preview(of content: Any?) -> String {
        let text: String = if let string = content as? String {
            string
        } else if let blocks = content as? [[String: Any]] {
            blocks.compactMap { $0["text"] as? String }.joined(separator: "\n")
        } else {
            ""
        }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").map {
            $0.count > resultLineLength ? String($0.prefix(resultLineLength)) + "…" : $0
        }
        guard lines.count > resultLines else { return lines.joined(separator: "\n") }
        return (lines.prefix(resultLines) + ["… \(lines.count - resultLines) more lines"]).joined(separator: "\n")
    }

    /// The text as shown, or nil for nothing to show: blank, or a reminder or
    /// notification Claude Code injected for the model rather than something said.
    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let injected = trimmed.hasPrefix("<system-reminder>") || trimmed.hasPrefix("[SYSTEM NOTIFICATION")
        return trimmed.isEmpty || injected ? nil : trimmed
    }
}
