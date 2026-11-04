import Foundation

/// The newest transcript in a host's project folder, plus its tail as whole
/// lines. `tail` is empty when the host found the file unchanged.
struct RemoteTranscript: Equatable {
    let file: TranscriptFile
    let tail: Data
}

/// Where a remote tab's transcript comes from. A seam so the probe's caching
/// and escalation are testable without ssh.
protocol RemoteTranscriptSource: Sendable {
    /// Newest `*.jsonl` in the host's `~/.claude/projects/<projectDirectory>`
    /// with its last `maxBytes` as whole lines — no body when it still matches
    /// `unchangedFrom`. nil when the folder holds no transcript; throws when
    /// the host couldn't be asked or the reply can't be read.
    func transcript(
        projectDirectory: String, maxBytes: Int, unchangedFrom: TranscriptFile?
    ) async throws -> RemoteTranscript?
}

/// Asks the host's `ygg transcript` over the shared ssh connection: one round
/// trip per tick, a one-line reply while the session is idle.
struct SSHTranscriptSource: RemoteTranscriptSource {
    enum Failure: Error, Equatable {
        case exit(code: Int32, stderr: String)
        /// Empty or malformed stdout. `ProcessRunner` returns "" for output
        /// that isn't valid UTF-8 — a tick that caught Claude mid-write
        /// through a multibyte character — so this is transient, not "none".
        case unreadableReply
    }

    let runner: SSHSubprocessRunner

    func transcript(
        projectDirectory: String, maxBytes: Int, unchangedFrom: TranscriptFile?
    ) async throws -> RemoteTranscript? {
        var arguments = "transcript \(CodingAgentRunner.shellQuote(projectDirectory)) \(maxBytes)"
        if let file = unchangedFrom {
            let mtime = Int(file.modified.timeIntervalSince1970)
            arguments += " \(mtime) \(file.size) \(CodingAgentRunner.shellQuote(file.path))"
        }
        let result = try await runner.runHelper(arguments)
        guard result.exitCode == 0 else {
            throw Failure.exit(code: result.exitCode, stderr: result.stderr)
        }
        return try Self.parse(result.stdout)
    }

    /// `none`, or `<mtime> <size> <path>\n` then the body. The path is last so
    /// a home directory with a space in it survives the split.
    static func parse(_ stdout: String) throws -> RemoteTranscript? {
        if stdout == "none\n" { return nil }
        guard let newline = stdout.firstIndex(of: "\n") else { throw Failure.unreadableReply }
        let fields = stdout[..<newline].split(separator: " ", maxSplits: 2)
        guard fields.count == 3,
              let mtime = TimeInterval(fields[0]),
              let size = UInt64(fields[1])
        else {
            throw Failure.unreadableReply
        }
        let file = TranscriptFile(
            path: String(fields[2]), modified: Date(timeIntervalSince1970: mtime), size: size
        )
        return RemoteTranscript(file: file, tail: Data(stdout[stdout.index(after: newline)...].utf8))
    }
}
