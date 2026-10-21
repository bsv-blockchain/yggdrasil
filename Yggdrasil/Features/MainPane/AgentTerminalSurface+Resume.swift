import Foundation

// MARK: - Claude session resume

extension AgentTerminalSurface {
    /// Resolved agent args plus the Claude session id the tab is pinned to.
    struct ResumePlan: Equatable {
        let args: [String]
        /// Nil when the tab isn't pinned: non-Claude agents, user-managed
        /// resume flags, and legacy tabs resumed via `--continue`.
        let sessionID: String?
    }

    /// What `session_state` says about the tab's Claude conversation.
    enum StoredSession: Equatable {
        /// No row: the tab has never spawned, so it's new.
        case noRow
        /// A row without an id: the tab predates v16.
        case unpinned
        case pinned(String)
        /// The row couldn't be read; never mint a new id over a possible pin.
        case unknown
    }

    /// Picks Claude's resume flags for a spawn. Only for the `claude` binary
    /// itself; wrappers (claude-squad, …) don't take these flags.
    ///  - Pinned id with a transcript → `--resume <id>`.
    ///  - Pinned id without one (no exchange yet) → `--session-id <id>`;
    ///    `--resume` of an unknown id exits 1.
    ///  - New tab → `--session-id <newSessionID>`, which the caller stores.
    ///  - Tab predating v16, or unreadable row → `--continue` when the cwd
    ///    has transcripts, as before. A legacy tab without any gets pinned.
    /// `--resume` searches every project dir, so a pinned transcript counts
    /// wherever it lives. Pure for testability.
    static func resolveResume(
        command: String,
        args: [String],
        cwd: String,
        stored: StoredSession,
        newSessionID: String,
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        directoryContents: (String) -> [String]? = {
            try? FileManager.default.contentsOfDirectory(atPath: $0)
        }
    ) -> ResumePlan {
        guard pinsClaudeSession(command: command, args: args) else { return ResumePlan(args: args, sessionID: nil) }
        let pinNew = ResumePlan(args: args + ["--session-id", newSessionID], sessionID: newSessionID)
        switch stored {
        case let .pinned(id):
            // The cwd's own project dir is the usual home; only scan the rest
            // when it isn't there.
            let projectsRoot = "\(home)/.claude/projects"
            let hasTranscript =
                fileExists("\(AgentSessionLocator.projectDirectory(forWorktreePath: cwd, home: home))/\(id).jsonl")
                    || (directoryContents(projectsRoot) ?? []).contains { dir in
                        directoryContents("\(projectsRoot)/\(dir)")?.contains("\(id).jsonl") ?? false
                    }
            return ResumePlan(args: args + [hasTranscript ? "--resume" : "--session-id", id], sessionID: id)
        case .noRow:
            return pinNew
        case .unpinned, .unknown:
            let entries = directoryContents(AgentSessionLocator.projectDirectory(forWorktreePath: cwd, home: home)) ??
                []
            if entries.contains(where: { $0.hasSuffix(".jsonl") }) {
                return ResumePlan(args: args + ["--continue"], sessionID: nil)
            }
            return stored == .unpinned ? pinNew : ResumePlan(args: args, sessionID: nil)
        }
    }

    /// True when the app should manage the Claude conversation id: the agent
    /// is claude and its profile doesn't already pick a session itself.
    static func pinsClaudeSession(command: String, args: [String]) -> Bool {
        // Only the claude binary itself; wrappers (claude-squad, …) don't
        // take these flags.
        guard (command as NSString).lastPathComponent.lowercased() == "claude" else { return false }
        let userFlags = ["--continue", "-c", "--resume", "-r", "--session-id", "--fork-session"]
        return !args.contains { arg in userFlags.contains { arg == $0 || arg.hasPrefix($0 + "=") } }
    }
}
