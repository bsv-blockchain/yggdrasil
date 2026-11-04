import Foundation

/// A tab's subagents: what's running, and what one of them has done.
extension TabActions {
    /// Whether the tab's agent is up: its terminal exists and hasn't exited.
    /// The same test as `running` in the control API's tab results.
    static func agentIsRunning(tabID: Int64, services: AppServices) -> Bool {
        services.sessions.terminal(for: tabID) != nil && services.sessions.exitedTabs[tabID] == nil
    }

    /// The tab's subagents that are still working, as the sidebar lists them.
    static func runningSubagents(tabID: Int64, services: AppServices) throws -> [SubagentInfo] {
        _ = try tab(tabID, services)
        return runningSubagents(tabID, services: services)
    }

    static func runningSubagents(_ tabID: Int64, services: AppServices) -> [SubagentInfo] {
        services.subagents.running(forTabID: tabID, parentRunning: agentIsRunning(tabID: tabID, services: services))
    }

    /// What subagent `agentID` of the tab has done so far, from its transcript.
    static func subagentTranscript(tabID: Int64, agentID: String, services: AppServices) throws -> [SubagentEntry] {
        let tab = try tab(tabID, services)
        guard tab.hostID == nil else { throw ActionError.invalidArgument("tab") }
        guard let path = SubagentProbe().transcriptPath(worktreePath: tab.worktreePath, agentID: agentID),
              let (data, fromStart) = try? LiveTranscriptFileSystem()
              .readTail(path: path, maxBytes: AgentSessionProbe.maxTailBytes)
        else { throw ActionError.invalidArgument("agent") }
        return SubagentTranscriptParser.entries(inTail: data, startsAtFileStart: fromStart)
    }
}
