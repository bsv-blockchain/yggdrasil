import Foundation

/// One subagent of a tab's Claude conversation, from its `meta.json`.
struct SubagentInfo: Equatable {
    let agentID: String
    let agentType: String
    let description: String
    /// 1 for one the tab's agent started; 2 for one a subagent started.
    let spawnDepth: Int
    /// Started with `run_in_background`: the tab's agent doesn't wait for it.
    let background: Bool
    /// When its transcript last grew; nil before it has one.
    let lastWrite: Date?
    /// Where its transcript is (or will be).
    let transcriptPath: String
}

/// Filesystem seam for `SubagentProbe`.
protocol SubagentFileSystem: TranscriptFileSystem {
    /// Names directly in `path`; empty when it doesn't exist.
    func fileNames(inDirectory path: String) -> [String]
    func contents(atPath path: String) -> Data?
    func dates(atPath path: String) -> (created: Date, modified: Date)?
}

/// Finds a tab's subagents. Claude Code keeps no PTY for them: they run inside
/// the tab's `claude`, and each writes `<session>/subagents/agent-<id>.jsonl`
/// next to the conversation's own transcript, with an `agent-<id>.meta.json`
/// that says what it is and whether it has finished.
struct SubagentProbe {
    let fileSystem: SubagentFileSystem
    let home: String

    init(fileSystem: SubagentFileSystem = LiveSubagentFileSystem(), home: String = NSHomeDirectory()) {
        self.fileSystem = fileSystem
        self.home = home
    }

    /// A meta file without `finished` (Claude Code before late October 2026)
    /// counts as running only while its transcript keeps growing.
    static let unmarkedActivityWindow: TimeInterval = 120

    /// The subagents still working, in the order they started, in the
    /// newest conversation of the worktree's project folder: the one the
    /// status dot reads, which follows the tab's claude across /clear.
    /// `since` is when the tab's agent started: a killed claude never marks
    /// its subagents finished, so anything not written since is a leftover.
    func unfinished(worktreePath: String, since: Date?, now: Date = Date()) -> [SubagentInfo] {
        guard let directory = subagentsDirectory(worktreePath: worktreePath) else { return [] }
        let found: [(info: SubagentInfo, started: Date)] = fileSystem.fileNames(inDirectory: directory)
            .compactMap { name in
                guard name.hasPrefix("agent-"), name.hasSuffix(".meta.json"),
                      let data = fileSystem.contents(atPath: "\(directory)/\(name)"),
                      let meta = try? JSONDecoder().decode(Meta.self, from: data),
                      meta.finished != true
                else { return nil }
                let agentID = String(name.dropFirst("agent-".count).dropLast(".meta.json".count))
                let path = "\(directory)/agent-\(agentID).jsonl"
                let dates = fileSystem.dates(atPath: path)
                if let since, let written = dates?.modified, written < since { return nil }
                if meta.finished == nil {
                    guard let written = dates?.modified,
                          now.timeIntervalSince(written) <= Self.unmarkedActivityWindow else { return nil }
                }
                let info = SubagentInfo(
                    agentID: agentID,
                    agentType: meta.agentType ?? "agent",
                    description: meta.description ?? "",
                    spawnDepth: meta.spawnDepth ?? 1,
                    background: meta.requestShape == "background",
                    lastWrite: dates?.modified,
                    transcriptPath: path
                )
                return (info, dates?.created ?? .distantFuture)
            }
        return found.sorted { lhs, rhs in
            lhs.started != rhs.started ? lhs.started < rhs.started : lhs.info.agentID < rhs.info.agentID
        }.map(\.info)
    }

    /// Where a subagent of the worktree's newest conversation keeps its
    /// transcript, whether or not it's still listed.
    func transcriptPath(worktreePath: String, agentID: String) -> String? {
        subagentsDirectory(worktreePath: worktreePath).map { "\($0)/agent-\(agentID).jsonl" }
    }

    private func subagentsDirectory(worktreePath: String) -> String? {
        let project = AgentSessionLocator.projectDirectory(forWorktreePath: worktreePath, home: home)
        return AgentSessionLocator.newest(among: fileSystem.transcripts(inDirectory: project)).map {
            let session = ($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".jsonl", with: "")
            return "\(project)/\(session)/subagents"
        }
    }

    private struct Meta: Decodable {
        let agentType: String?
        let description: String?
        let spawnDepth: Int?
        let requestShape: String?
        let finished: Bool?
    }
}

/// The real filesystem; failures read as "nothing there", as in
/// `LiveTranscriptFileSystem`, since this runs every few seconds per tab.
struct LiveSubagentFileSystem: SubagentFileSystem {
    private let transcriptsFS = LiveTranscriptFileSystem()

    func fileNames(inDirectory path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    func contents(atPath path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    func dates(atPath path: String) -> (created: Date, modified: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return ((attributes[.creationDate] as? Date) ?? modified, modified)
    }

    func transcripts(inDirectory path: String) -> [TranscriptFile] {
        transcriptsFS.transcripts(inDirectory: path)
    }

    func readTail(path: String, maxBytes: Int) throws -> (data: Data, startsAtFileStart: Bool) {
        try transcriptsFS.readTail(path: path, maxBytes: maxBytes)
    }
}
