import Foundation

/// A host's newest conversation and its subagents' meta files.
struct RemoteSubagentList: Equatable {
    /// nil when the project folder has no conversation.
    let conversationID: String?
    let entries: [SubagentMetaEntry]
}

/// A subagent transcript's tail from a host.
enum SubagentTail: Equatable {
    /// No such transcript.
    case none
    /// Still the size the caller already has.
    case unchanged
    /// Its last bytes as whole lines, and the file's size.
    case lines(Data, size: UInt64)
}

/// Where a remote tab's subagents come from. A seam so the probe's rules
/// are testable without ssh.
protocol RemoteSubagentSource: Sendable {
    func subagents(projectDirectory: String) async throws -> RemoteSubagentList
    func tail(
        projectDirectory: String, conversationID: String, agentID: String, maxBytes: Int, knownSize: UInt64?
    ) async throws -> SubagentTail
}

/// Asks the host's `ygg subagents` / `ygg subagent-tail` over the shared ssh
/// connection.
struct SSHSubagentSource: RemoteSubagentSource {
    enum Failure: Error, Equatable {
        case exit(code: Int32, stderr: String)
        /// Empty or malformed stdout; transient, like `SSHTranscriptSource`'s.
        case unreadableReply
    }

    let runner: SSHSubprocessRunner

    func subagents(projectDirectory: String) async throws -> RemoteSubagentList {
        try await Self.parseSubagents(run("subagents \(CodingAgentRunner.shellQuote(projectDirectory))"))
    }

    func tail(
        projectDirectory: String, conversationID: String, agentID: String, maxBytes: Int, knownSize: UInt64?
    ) async throws -> SubagentTail {
        var arguments = "subagent-tail \(CodingAgentRunner.shellQuote(projectDirectory)) "
            + "\(CodingAgentRunner.shellQuote(conversationID)) \(CodingAgentRunner.shellQuote(agentID)) \(maxBytes)"
        if let knownSize { arguments += " \(knownSize)" }
        return try await Self.parseTail(run(arguments))
    }

    private func run(_ arguments: String) async throws -> String {
        let result = try await runner.runHelper(arguments)
        guard result.exitCode == 0 else { throw Failure.exit(code: result.exitCode, stderr: result.stderr) }
        return result.stdout
    }

    /// A `subagents [<conversation>]` header, then
    /// `<id>\t<mtime>\t<birth>\t<meta json>` per unfinished agent; `-` for a
    /// transcript not written yet, birth `0` where the host's filesystem
    /// doesn't record it.
    static func parseSubagents(_ stdout: String) throws -> RemoteSubagentList {
        var lines = stdout.split(separator: "\n", omittingEmptySubsequences: true)
        guard let header = lines.first, header == "subagents" || header.hasPrefix("subagents ") else {
            throw Failure.unreadableReply
        }
        lines.removeFirst()
        let conversation = header.dropFirst("subagents".count).trimmingCharacters(in: .whitespaces)
        let entries = try lines.map { line in
            let fields = line.split(separator: "\t", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4, !fields[0].isEmpty else { throw Failure.unreadableReply }
            return SubagentMetaEntry(
                agentID: String(fields[0]),
                meta: Data(fields[3].utf8),
                modified: date(fields[1]),
                created: date(fields[2]),
                transcriptPath: "\(conversation)/subagents/agent-\(fields[0]).jsonl"
            )
        }
        return RemoteSubagentList(conversationID: conversation.isEmpty ? nil : conversation, entries: entries)
    }

    /// `none`, `same <size>`, or `ok <size>` then the lines.
    static func parseTail(_ stdout: String) throws -> SubagentTail {
        if stdout == "none\n" { return .none }
        guard let newline = stdout.firstIndex(of: "\n") else { throw Failure.unreadableReply }
        let header = stdout[..<newline].split(separator: " ")
        guard header.count == 2, let size = UInt64(header[1]) else { throw Failure.unreadableReply }
        switch header[0] {
        case "same": return .unchanged
        case "ok": return .lines(Data(stdout[stdout.index(after: newline)...].utf8), size: size)
        default: throw Failure.unreadableReply
        }
    }

    private static func date(_ field: Substring) -> Date? {
        guard let seconds = TimeInterval(field), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
