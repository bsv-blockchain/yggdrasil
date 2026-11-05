import Foundation

/// The pinned "Yggdrasil" session: Claude with the Yggdrasil MCP loaded, for
/// managing the other tabs. It runs `yggctl mcp`, which reaches the control
/// API over its socket with a key made for this session.
@MainActor
enum ManagerSession {
    /// The key's name in Settings → API.
    static let keyName = "Yggdrasil session (built-in)"

    static func folder(dataDirectory: URL = DataDirectory.url()) -> URL {
        dataDirectory.appendingPathComponent("manager", isDirectory: true)
    }

    /// Its tab row, made the first time it's opened.
    static func ensureTab(services: AppServices, dataDirectory: URL = DataDirectory.url()) throws -> YggdrasilTab {
        let tab = try services.tabStore.ensureManager(
            worktreePath: folder(dataDirectory: dataDirectory).path,
            agentID: services.agentStore.getDefault()?.id
        )
        if services.tabs.managerTab?.id != tab.id { services.tabs.reload() }
        return tab
    }

    /// What to run: the default agent's `claude` with its arguments, or plain
    /// `claude` when the default is another agent, plus the MCP config. The
    /// key goes in the environment, which `yggctl mcp` inherits, so it's in
    /// no file and on no command line.
    static func session(
        tab: YggdrasilTab, services: AppServices, dataDirectory: URL = DataDirectory.url(),
        yggctlPath: String, socketPath: String
    ) throws -> OpenSession {
        guard let id = tab.id else { throw ActionError.unknownTab(0) }
        let folder = folder(dataDirectory: dataDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The user's own notes; the app's instructions go in the system prompt.
        let notes = folder.appendingPathComponent("CLAUDE.md")
        if !FileManager.default.fileExists(atPath: notes.path) {
            try notesTemplate.write(to: notes, atomically: true, encoding: .utf8)
        }
        let config = folder.appendingPathComponent("mcp.json")
        try mcpConfig(yggctlPath: yggctlPath).write(to: config, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        let settings = folder.appendingPathComponent("settings.json")
        try settingsFile(yggctlPath: yggctlPath).write(to: settings, options: .atomic)

        let agent = try services.agentStore.getDefault()
        let isClaude = agent.map { ($0.command as NSString).lastPathComponent.lowercased() == "claude" } ?? false
        var env = isClaude ? agent?.env ?? [:] : [:]
        env["YGGDRASIL_API_KEY"] = try key(services: services)
        env["YGGDRASIL_SOCKET"] = socketPath
        return OpenSession(
            id: id,
            displayName: "Yggdrasil",
            cwd: folder.path,
            command: isClaude ? agent?.command ?? "claude" : "claude",
            args: (isClaude ? agent?.args ?? [] : [])
                + [
                    // Only this MCP server: the key is in the environment,
                    // which every other server would inherit too.
                    "--mcp-config", config.path, "--strict-mcp-config", "--settings", settings.path,
                    "--append-system-prompt", instructions
                ],
            env: env,
            host: nil,
            initialPrompt: nil
        )
    }

    /// Starts it again, with its conversation, after it ended.
    static func restart(tab: YggdrasilTab, services: AppServices) throws {
        guard let id = tab.id, let control = services.control else { return }
        let session = try session(
            tab: tab, services: services, yggctlPath: ControlService.yggctlPath, socketPath: control.socketPath
        )
        services.sessions.clearExited(tabID: id)
        services.sessions.terminate(tabID: id)
        // The next turn, once SwiftUI has let go of the old terminal.
        DispatchQueue.main.async { services.sessions.add(session) }
    }

    /// Revokes every key this session made: at quit, and at launch for a run
    /// that crashed before it could.
    static func revokeKeys(services: AppServices) {
        let store = APIKeyStore(database: services.database)
        for key in (try? store.list()) ?? [] where key.name == keyName {
            if let id = key.id { try? store.revoke(id: id) }
        }
        services.managerKeySecret = nil
    }

    /// One full key per app run, kept in memory only.
    private static func key(services: AppServices) throws -> String {
        // Still valid? It has a Revoke button in Settings → API like any key.
        if let secret = services.managerKeySecret,
           (try? APIKeyStore(database: services.database).verify(secret: secret)) != nil {
            return secret
        }
        let secret = try APIKeyStore(database: services.database).create(name: keyName, scope: .full).secret
        services.managerKeySecret = secret
        return secret
    }

    /// Full-scope tools the session may use without Claude Code asking:
    /// opening, starting and showing tabs, and housekeeping. Every other
    /// full-scope tool asks, so an action added later asks by default.
    static let freeTools: Set<String> = [
        "tab_open", "tab_openTask", "tab_openIssue", "tab_start", "tab_select", "tab_selectRelative",
        "tab_mute", "tab_unmute", "tab_retrySetup", "tab_reloadGitHub", "tab_setLayout", "tab_setDiffScope",
        "tab_reorder", "tab_openInFinder", "tab_openInTerminal", "sync_now", "app_checkForUpdates",
        "app_revealCrashLogs"
    ]

    /// The tools Claude Code asks the user about, even with
    /// --dangerously-skip-permissions: the prompt's own rule wasn't enough,
    /// as the model took "close X" as the go-ahead.
    static var confirmedTools: [String] {
        ActionCatalog.all
            .filter { $0.scope == .full && !freeTools.contains($0.toolName) }
            .map(\.toolName)
    }

    /// The ask rules, and deny rules for reaching the API from the shell
    /// around them: the key is in the shell's environment too. Prefix rules
    /// only, so a wrapped command (`sh -c …`) isn't caught.
    private static func settingsFile(yggctlPath: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["permissions": [
                "ask": confirmedTools.map { "mcp__yggdrasil__\($0)" },
                "deny": ["Bash(yggctl:*)", "Bash(\(yggctlPath):*)", "Bash(curl:*)"]
            ]],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func mcpConfig(yggctlPath: String) throws -> Data {
        try JSONSerialization.data(
            withJSONObject: ["mcpServers": ["yggdrasil": ["command": yggctlPath, "args": ["mcp"]]]],
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }

    static let notesTemplate = """
    # Notes for the Yggdrasil session

    Claude reads this file at the start of every Yggdrasil session. Put your own
    preferences here: which host new tabs go to, how you name branches, what to
    check first. Yggdrasil never changes it.

    """

    /// The session's system prompt: what it's for, how to read the tools'
    /// results, and what to ask before doing.
    static let instructions = """
    You are the Yggdrasil session: a coordinator for the user's coding tabs, running \
    inside Yggdrasil.

    Yggdrasil runs coding agents, mostly Claude, in tabs. Each tab is a git branch in its \
    own worktree, on this Mac or on an ssh host, usually tied to a GitHub issue or PR. The \
    `yggdrasil` MCP tools can do anything the user can do in the app.

    You coordinate; the work happens in the tabs. Don't write code or edit files yourself: \
    this session's folder isn't a project. To get code written, use a tab and give its \
    agent the task.

    Reading the tabs
    - `tabs_list` (`tabs_get` for one) gives every tab's `id`, which every other call takes, \
    plus `repo`, `branch`, `host` (null means this Mac), `agent`, `task` (the issue or PR \
    it's for) and `linkedPR`.
    - `running`: its agent process is up. `status.icon`: `awaitingInput` (the agent asked \
    something), `errored`, `ciFailing`, `dirty` (uncommitted changes), `unread` (new GitHub \
    activity), `running` (mid-turn) or `idle`. A dirty tree or unread activity hides \
    `running` in the icon; `status.summary` spells out each part.
    - `needsAttention`: the tab wants the user, as the sidebar's "Needs me" shows it. \
    `runningSubagents`: subagents its agent has going.
    - `tab_screen` reads an agent's terminal (`scrollback` for more lines). Read it rather \
    than guess what an agent is doing.
    - `tab_subagents` lists a tab's running subagents; `tab_subagentTranscript` shows what \
    one has done.
    - `reviews_list`: PRs waiting for the user's review that have no tab yet. `tasks_list`: \
    assigned issues and PRs with no tab. `issues_list`: the user's issues. `state_get`: \
    repos, hosts, agents and settings.

    Acting
    - `tab_open` opens a tab for a repo and branch (a GitHub URL or `#123` works as the \
    branch); `prompt` gives its Claude a first task. `tab_openTask` and `tab_openIssue` \
    open one from the lists above. A new tab's agent starts when the user shows it, or \
    with `tab_start`, which doesn't change what the user is looking at.
    - `tab_send` types into an agent and presses Enter (`submit: false` only types). It \
    arrives as a paste; for a menu, or a key like Escape, send it with `paste: false` \
    (Down is ESC [ B). Read `tab_screen` first: text sent to an agent mid-turn waits \
    behind its work.
    - `tab_select` shows a tab to the user.

    Confirm before anything that loses work or interrupts it, even when the user asked \
    for it: closing a tab (`tab_close`), `tab_terminate`, `tab_restart`, `tab_shell`, \
    `tab_move`, typing into an agent that's mid-turn or waiting on a question meant for \
    the user, and removing a repository, agent or host. Say exactly what you're about to \
    do (the tab's id and branch, and for a close whether its worktree is deleted), then \
    wait for an explicit yes before the call. A request like "close X" is not that yes. \
    Claude Code also asks the user before most of these tools run; say what you're doing \
    first anyway. Reading is always fine.

    Common asks
    - "What needs me?": `tabs_list`, then `tab_screen` for each tab with \
    `needsAttention`, `awaitingInput` or `errored`, to say what it wants. Mention \
    `reviews_list` when it isn't empty.
    - "What's everyone doing?": one line per tab, reading `tab_screen` for the busy ones.
    - "Start on issue X": find it with `tasks_list` or `issues_list` (or use the repo and \
    number), open it with `tab_openTask`, `tab_openIssue` or `tab_open` with a `prompt`, \
    then `tab_start`.

    Keep answers short: the tab's id and branch, and what matters.
    """
}
