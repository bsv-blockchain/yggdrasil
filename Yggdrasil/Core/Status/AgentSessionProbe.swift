import Foundation

/// One transcript file on disk, reduced to what the probe needs to decide
/// whether it has to be read again.
struct TranscriptFile: Equatable {
    let path: String
    let modified: Date
    let size: UInt64
}

/// Filesystem seam, so the caching policy is testable without touching disk.
protocol TranscriptFileSystem: Sendable {
    /// Depth-1 `*.jsonl` in `path`. Empty when the directory doesn't exist.
    func transcripts(inDirectory path: String) -> [TranscriptFile]
    /// The last `maxBytes` of the file. `startsAtFileStart` is false when the
    /// window begins mid-file, so the caller knows the first line is a fragment.
    func readTail(path: String, maxBytes: Int) throws -> (data: Data, startsAtFileStart: Bool)
}

/// Where an agent keeps the transcript for a given working directory.
enum AgentSessionLocator {
    /// Claude maps a cwd to `~/.claude/projects/<encoded>` by replacing every
    /// character outside `[A-Za-z0-9]` with `-` — not just `/` and `.`.
    ///
    /// The distinction is load-bearing and fails silently when you get it
    /// wrong: `BranchSlug` deliberately keeps `_` in branch slugs, so a branch
    /// like `fix/update_cache` produces a worktree Claude records under
    /// `…-fix-update-cache` while a `/`-and-`.`-only encoder looks for
    /// `…-fix-update_cache`, finds no directory, and reports no state forever.
    /// Same for a repo path containing a space, `+`, `@` or anything non-ASCII.
    /// Verified against the real encoder and against every project directory on
    /// this machine — all 105 contain only alphanumerics and dashes.
    ///
    /// Known limit: Claude truncates at 200 characters and appends a hash of
    /// the original. Paths that long aren't reachable here (the longest real
    /// one is 86), and guessing the hash would be worse than not finding the
    /// directory, so this deliberately doesn't try.
    static func encode(cwd: String) -> String {
        String(cwd.map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        })
    }

    static func projectDirectory(forWorktreePath path: String, home: String = NSHomeDirectory()) -> String {
        "\(home)/.claude/projects/\(encode(cwd: path))"
    }

    /// Newest by modification time; ties broken by path so a tab can't flip
    /// between two files from tick to tick.
    static func newest(among files: [TranscriptFile]) -> TranscriptFile? {
        files.max { lhs, rhs in
            if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
            return lhs.path > rhs.path
        }
    }
}

/// Reads the newest activity out of a tab's session transcript, doing as little
/// I/O as it can get away with.
///
/// Stateless by design: the per-tab cache is handed in and handed back, so the
/// caller (`StatusPoller`, an actor) owns it and the probe stays a value type.
struct AgentSessionProbe {
    /// What the last probe saw, so an untouched file costs no read at all.
    struct Cache: Equatable {
        let path: String
        let modified: Date
        let size: UInt64
        /// nil means "looked and found nothing parseable" — cached too, or a
        /// transcript with no conversation records is re-read every 5 seconds.
        let sample: AgentActivitySample?
    }

    /// Covers the measured distribution: across real transcripts the newest
    /// conversation record sat within 58KB of the end, worst case, and a single
    /// line can reach 136KB.
    static let initialTailBytes = 128 * 1024
    /// One escalation for the rare file whose tail is all bookkeeping.
    static let maxTailBytes = 1024 * 1024

    let fileSystem: TranscriptFileSystem

    init(fileSystem: TranscriptFileSystem = LiveTranscriptFileSystem()) {
        self.fileSystem = fileSystem
    }

    func probe(
        worktreePath: String,
        agent: AgentIdentity,
        previous: Cache?
    ) -> (sample: AgentActivitySample?, cache: Cache?) {
        // Codex stores rollouts under ~/.codex/sessions/<date>/ keyed by
        // session id, not by directory, so locating one means indexing every
        // rollout's first record. Not built yet — and it must report nothing
        // rather than guess, since a wrong state is worse than no state.
        guard agent != .codex else { return (nil, nil) }

        let directory = AgentSessionLocator.projectDirectory(forWorktreePath: worktreePath)
        guard let file = AgentSessionLocator.newest(among: fileSystem.transcripts(inDirectory: directory)) else {
            return (nil, nil)
        }

        if let previous,
           previous.path == file.path,
           previous.modified == file.modified,
           previous.size == file.size {
            return (previous.sample, previous)
        }

        let sample = read(file: file, agent: agent)
        return (sample, Cache(path: file.path, modified: file.modified, size: file.size, sample: sample))
    }

    private func read(file: TranscriptFile, agent: AgentIdentity) -> AgentActivitySample? {
        for limit in [Self.initialTailBytes, Self.maxTailBytes] {
            guard let (data, startsAtFileStart) = try? fileSystem.readTail(path: file.path, maxBytes: limit) else {
                return nil
            }
            if let sample = AgentTranscriptParser.latestActivity(
                inTail: data, agent: agent, chunkStartsAtFileStart: startsAtFileStart
            ) {
                return sample
            }
            // Already had the whole file in hand; a bigger window won't help.
            if startsAtFileStart { return nil }
        }
        return nil
    }
}

/// Real filesystem. Failures are swallowed into "nothing found": this runs
/// every few seconds per tab, so a missing directory or an unreadable file is
/// an ordinary condition, not something to log about.
struct LiveTranscriptFileSystem: TranscriptFileSystem {
    func transcripts(inDirectory path: String) -> [TranscriptFile] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: path) else { return [] }
        return names.compactMap { name in
            guard name.hasSuffix(".jsonl") else { return nil }
            let full = "\(path)/\(name)"
            guard let attributes = try? manager.attributesOfItem(atPath: full),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? NSNumber
            else {
                return nil
            }
            return TranscriptFile(path: full, modified: modified, size: size.uint64Value)
        }
    }

    func readTail(path: String, maxBytes: Int) throws -> (data: Data, startsAtFileStart: Bool) {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let wanted = UInt64(maxBytes)
        let offset = size > wanted ? size - wanted : 0
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        return (data, offset == 0)
    }
}
