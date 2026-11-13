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

    /// A remote call's limit: the helper is one ssh round trip, but a
    /// dropped connection would otherwise hang the caller.
    static let remoteDeadline: Duration = .seconds(20)

    static func remoteSubagentSource(_ host: RemoteHost) -> SSHSubagentSource {
        SSHSubagentSource(runner: SSHSubprocessRunner(host: host, transport: ProcessRunner(terminatesOnCancel: true)))
    }

    /// What subagent `agentID` of the tab has done so far, from its
    /// transcript: read here, or with `ygg subagent-tail` on the tab's host.
    /// Parsed off the main actor: the tail can be a megabyte.
    static func subagentTranscript(
        tabID: Int64, agentID: String, services: AppServices
    ) async throws -> [SubagentEntry] {
        let tab = try tab(tabID, services)
        // Checked here too: the helper answers a bad id with its usage error,
        // which the app reads as "old helper" and reinstalls it.
        guard !agentID.isEmpty, agentID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw ActionError.invalidArgument("agent")
        }
        if let hostID = tab.hostID {
            guard let host = services.host(for: tab) else { throw ActionError.unknownHost(hostID) }
            let source = remoteSubagentSource(host)
            let directory = AgentSessionLocator.encode(cwd: tab.worktreePath)
            let tail = try await withDeadline(remoteDeadline) { () -> SubagentTail in
                guard let conversation = try await source.subagents(projectDirectory: directory).conversationID else {
                    return .none
                }
                return try await source.tail(
                    projectDirectory: directory, conversationID: conversation, agentID: agentID,
                    maxBytes: AgentSessionProbe.maxTailBytes, knownSize: nil
                )
            }
            guard case let .lines(data, _) = tail else { throw ActionError.invalidArgument("agent") }
            // The host sends whole lines only.
            return await Task.detached { SubagentTranscriptParser.entries(inTail: data, startsAtFileStart: true) }.value
        }
        guard let path = SubagentProbe().transcriptPath(worktreePath: tab.worktreePath, agentID: agentID) else {
            throw ActionError.invalidArgument("agent")
        }
        let parsed = await Task.detached { () -> [SubagentEntry]? in
            guard let (data, fromStart) = try? LiveTranscriptFileSystem()
                .readTail(path: path, maxBytes: AgentSessionProbe.maxTailBytes)
            else { return nil }
            return SubagentTranscriptParser.entries(inTail: data, startsAtFileStart: fromStart)
        }.value
        guard let parsed else { throw ActionError.invalidArgument("agent") }
        return parsed
    }
}
