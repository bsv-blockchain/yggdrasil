import Foundation

/// How the app's models look in control API results, and how arguments that
/// name a repo, host or agent are resolved.
@MainActor
enum ControlEncoding {
    // MARK: - Results

    /// The process's exit code from the raw wait status the terminal reports;
    /// 128 + the signal when a signal ended it, as a shell shows it.
    nonisolated static func exitStatus(_ raw: Int32) -> Int32 {
        guard raw >= 0 else { return raw }
        let signal = raw & 0x7F
        return signal == 0 ? (raw >> 8) & 0xFF : 128 + signal
    }

    static func tab(_ tab: YggdrasilTab, services: AppServices) -> JSONValue {
        guard let id = tab.id else { return .null }
        let sessions = services.sessions
        let status = services.tabStatus.status(forTabID: id)
        let dismissed = AttentionDismissal.dismissedSignature(tabID: id)
        let agent = tab.codingAgentID.flatMap { try? services.agentStore.get(id: $0) }
        let exitCode = sessions.exitedTabs[id]
        var fields: [String: JSONValue] = [:]
        fields["id"] = .int(id)
        fields["repo"] = .optional(services.tabs.repoByTabID[id]?.fullName)
        fields["branch"] = .string(tab.branchName)
        fields["worktree"] = .string(tab.worktreePath)
        fields["host"] = .optional(services.host(for: tab)?.name)
        fields["agent"] = .optional(agent?.name)
        fields["preparation"] = .string(tab.preparationState.rawValue)
        fields["preparationError"] = .optional(tab.preparationError)
        fields["running"] = .bool(sessions.terminal(for: id) != nil && exitCode == nil)
        fields["exitCode"] = exitCode.map { .int(exitStatus($0)) } ?? .null
        fields["reconnecting"] = .bool(sessions.reconnecting.contains(id))
        fields["moving"] = .bool(sessions.movingTabs.contains(id))
        fields["opened"] = .bool(sessions.isOpened(tabID: id))
        fields["selected"] = .bool(services.tabs.selectedID == id)
        fields["layout"] = .string(PaneLayout.load(for: tab).rawValue)
        fields["needsAttention"] = .bool(TabRowViewModel.needsAttention(
            branchName: tab.branchName, status: status, dismissedSignature: dismissed
        ))
        fields["muted"] = .bool(AttentionSignature.isDismissed(
            current: status.attentionSignature,
            dismissed: dismissed
        ))
        fields["status"] = statusFields(status)
        fields["task"] = services.tabs.tasksByTabID[id].map { task(task: $0, repo: nil) } ?? .null
        fields["linkedPR"] = services.tabs.prTasksByTabID[id].map { task(task: $0, repo: nil) } ?? .null
        return .object(fields)
    }

    private static func statusFields(_ status: TabStatus) -> JSONValue {
        var fields: [String: JSONValue] = [:]
        fields["icon"] = .string(status.icon.rawValue)
        fields["summary"] = .array(status.tooltipLines.map(JSONValue.string))
        fields["reviewState"] = .optional(status.reviewState)
        fields["reviewActivity"] = .bool(status.reviewActivity)
        fields["reviewApproved"] = .bool(status.reviewApproved)
        fields["newCommits"] = .int(status.newCommits)
        fields["threadsAwaitingReply"] = .int(status.threadsAwaitingReply)
        return .object(fields)
    }

    static func task(task: YggdrasilTask, repo: Repo?) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .optional(task.id),
            "type": .string(task.type == .pullRequest ? "pr" : "issue"),
            "number": .int(task.number),
            "title": .string(task.title),
            "state": .string(task.state.rawValue),
            "author": .string(task.authorLogin),
            "url": .string(task.githubURL)
        ]
        if let repo { fields["repo"] = .string(repo.fullName) }
        return .object(fields)
    }

    static func repo(_ repo: Repo) -> JSONValue {
        .object([
            "id": .optional(repo.id),
            "repo": .string(repo.fullName),
            "defaultBranch": .string(repo.defaultBranch),
            "localPath": .optional(repo.localMainPath)
        ])
    }

    static func host(_ host: RemoteHost, isDefault: Bool) -> JSONValue {
        .object([
            "id": .optional(host.id),
            "name": .string(host.name),
            "sshTarget": .string(host.sshTarget),
            "reposRoot": .string(host.reposRoot),
            "default": .bool(isDefault)
        ])
    }

    /// Environment values are typically tokens: only their names. Arguments
    /// can hold one too, so they're only for full keys.
    static func agent(_ agent: CodingAgent, includeArgs: Bool = true) -> JSONValue {
        var fields: [String: JSONValue] = [
            "id": .optional(agent.id),
            "name": .string(agent.name),
            "command": .string(agent.command),
            "envNames": .array(agent.env.keys.sorted().map(JSONValue.string)),
            "default": .bool(agent.isDefault)
        ]
        if includeArgs { fields["args"] = .array(agent.args.map(JSONValue.string)) }
        return .object(fields)
    }

    static func settings(_ settings: SettingsActions.Snapshot) -> JSONValue {
        .object([
            "theme": .string(settings.theme.rawValue),
            "terminalTheme": .string(settings.terminalTheme.rawValue),
            "groupByRepo": .bool(settings.groupByRepo),
            "defaultHostID": .optional(settings.defaultHostID),
            "syncSeconds": .int(settings.syncSeconds),
            "statusProbeSeconds": .int(settings.statusProbeSeconds)
        ])
    }

    static func screen(_ screen: TerminalControl.Screen) -> JSONValue {
        .object([
            "lines": .array(screen.lines.map(JSONValue.string)),
            "scrollback": .array(screen.scrollback.map(JSONValue.string)),
            "cursor": .object(["row": .int(screen.cursorRow), "column": .int(screen.cursorColumn)]),
            "alternateScreen": .bool(screen.alternateScreen)
        ])
    }

    // MARK: - Arguments

    /// An `owner/name` (any case) or a repo id.
    static func repo(named value: String, services: AppServices) throws -> Repo {
        let repos = try services.database.queue.read { db in try Repo.fetchAll(db) }
        if let id = Int64(value), let repo = repos.first(where: { $0.id == id }) { return repo }
        let slug = RepoPrefsPane.parseSlug(value).map { "\($0.owner)/\($0.name)".lowercased() }
        guard let repo = repos.first(where: { $0.fullName.lowercased() == slug }) else {
            throw ActionError.invalidArgument("repo")
        }
        return repo
    }

    /// `local` for this Mac, a host's name or id, or nil for the default.
    static func host(named value: String?, services: AppServices) throws -> RemoteHost? {
        guard let value else { return services.defaultHost }
        if value.lowercased() == "local" { return nil }
        let hosts = try services.hostStore.list()
        guard let host = hosts.first(where: { $0.name == value || $0.id.map(String.init) == value }) else {
            throw ActionError.invalidArgument("host")
        }
        return host
    }

    /// An agent's name (any case) or id, or nil for the default.
    static func agent(named value: String?, services: AppServices) throws -> CodingAgent {
        let agents = try services.agentStore.list()
        guard let value else {
            guard let agent = try services.agentStore.getDefault() ?? agents.first else {
                throw ActionError.invalidArgument("agent")
            }
            return agent
        }
        guard let agent = agents.first(where: {
            $0.name.lowercased() == value.lowercased() || $0.id.map(String.init) == value
        }) else { throw ActionError.invalidArgument("agent") }
        return agent
    }
}
