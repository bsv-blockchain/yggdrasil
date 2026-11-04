import AppKit
import Foundation
import GRDB

// One entry per user action; splitting it would only scatter the list.
// swiftlint:disable type_body_length

/// Everything the control API can do. Each entry calls the same action the
/// menus, sidebar, sheets and Settings use, so the API and the UI can't
/// drift apart. `ActionCatalogTests` lists what must be here.
@MainActor
enum ActionCatalog {
    static var all: [ControlAction] {
        reading + tabs + repos + agents + hosts + app
    }

    private typealias Param = ControlAction.Param

    private static let tabParam = Param("tab", .integer, "The tab's id, from tabs_list.")

    // MARK: - Reading

    private static var reading: [ControlAction] {
        [
            ControlAction(
                name: "state.get",
                summary: "Repositories, hosts, agents, settings and the counts behind the sidebar badges.",
                scope: .read, params: []
            ) { _, context in
                let services = context.services
                let repos = try await services.database.queue.read { db in try Repo.fetchAll(db) }
                let defaultHost = services.defaultHostID
                return try .object([
                    "repos": .array(repos.map(ControlEncoding.repo)),
                    "hosts": .array(services.hostStore.list().map {
                        ControlEncoding.host($0, isDefault: $0.id == defaultHost)
                    }),
                    "agents": .array(services.agentStore.list().map {
                        ControlEncoding.agent($0, includeArgs: context.key?.scope != .read)
                    }),
                    "settings": ControlEncoding.settings(SettingsActions.read(services: services)),
                    "reviewsWaiting": .int(services.tabs.pendingReviewCount),
                    "assignedWaiting": .int(services.tabs.pendingAssignedCount),
                    "selectedTab": .optional(services.tabs.selectedID),
                    "keyScope": .optional(context.key?.scope.rawValue)
                ])
            },
            ControlAction(
                name: "tabs.list",
                summary: "All tabs in sidebar order, with their agent's state, git and GitHub status, and whether they need the user.",
                scope: .read, params: []
            ) { _, context in
                .array(context.services.tabs.tabs.map { ControlEncoding.tab($0, services: context.services) })
            },
            ControlAction(name: "tabs.get", summary: "One tab, as in tabs_list.", scope: .read,
                          params: [tabParam]) { params, context in
                try ControlEncoding.tab(TabActions.tab(params.int("tab"), context.services), services: context.services)
            },
            ControlAction(
                name: "tab.screen",
                summary: "The text on a tab's agent terminal, plus lines scrolled off above it.",
                scope: .read,
                params: [
                    tabParam,
                    Param("scrollback", .integer, "Lines from above the screen. Default 0.", required: false)
                ]
            ) { params, context in
                let screen = try TabActions.screen(
                    tabID: params.int("tab"), scrollback: Int(params.optionalInt("scrollback") ?? 0),
                    services: context.services
                )
                return ControlEncoding.screen(screen)
            },
            ControlAction(
                name: "tab.subagents",
                summary: "The subagents a tab's Claude is running, as the sidebar lists them under the tab.",
                scope: .read,
                params: [tabParam]
            ) { params, context in
                try .array(TabActions.runningSubagents(tabID: params.int("tab"), services: context.services)
                    .map(ControlEncoding.subagent))
            },
            // Full scope: its tool results can hold anything a command printed
            // or a file contained, unlike the one screen tab_screen shows.
            ControlAction(
                name: "tab.subagentTranscript",
                summary: "What one of a tab's subagents has done so far: its task, text, tool calls and results.",
                scope: .full,
                params: [tabParam, Param("agent", .string, "A subagent id from tab_subagents.")]
            ) { params, context in
                try .array(TabActions.subagentTranscript(
                    tabID: params.int("tab"), agentID: params.string("agent"), services: context.services
                ).map(ControlEncoding.subagentEntry))
            },
            ControlAction(
                name: "reviews.list",
                summary: "PRs waiting for the user's review that have no tab yet (Review Requests).",
                scope: .read, params: []
            ) { _, context in
                try await taskList(TaskQueries.toReview, services: context.services)
            },
            ControlAction(
                name: "tasks.list",
                summary: "Issues assigned to the user and PRs they wrote that have no tab yet (Assigned Tasks).",
                scope: .read, params: []
            ) { _, context in
                try await taskList(TaskQueries.assigned, services: context.services)
            },
            ControlAction(
                name: "issues.list",
                summary: "Every issue assigned to the user on GitHub, in any repository (My Issues), with a linked PR when one is known.",
                scope: .read, params: []
            ) { _, context in
                try await issues(services: context.services)
            },
            ControlAction(
                name: "diagnostics.get", summary: "Versions, paths and recent log lines (Help ▸ Diagnostics).",
                scope: .read, params: []
            ) { _, _ in
                .string(AppActions.diagnosticsReport())
            }
        ]
    }

    private static func taskList(
        _ query: @escaping @Sendable (Database) throws -> [YggdrasilTask], services: AppServices
    ) async throws -> JSONValue {
        let (tasks, repos) = try await services.database.queue.read { db in try (query(db), Repo.fetchAll(db)) }
        return .array(tasks.map { task in
            ControlEncoding.task(task: task, repo: repos.first { $0.id == task.repoID })
        })
    }

    private static func issues(services: AppServices) async throws -> JSONValue {
        let raws = try await services.restClient.allAssignedIssues()
        let (prs, repos) = try await services.database.queue.read { db in
            try (YggdrasilTask.fetchAll(db, sql: "SELECT * FROM task WHERE type = 'pr'"), Repo.fetchAll(db))
        }
        let reposByKey = Dictionary(repos.map { ("\($0.owner)/\($0.name)", $0) }) { first, _ in first }
        return .array(raws.map { raw in
            let key = "\(raw.repoOwner)/\(raw.repoName)"
            let linked = IssueDetailsPicker.linkedPR(
                forIssueNumber: raw.number, repoKey: key, candidatePRs: prs, repos: reposByKey
            )
            return .object([
                "repo": .string(key),
                "number": .int(raw.number),
                "title": .string(raw.title),
                "state": .string(raw.state.rawValue),
                "url": .string(raw.githubURL),
                "tracked": .bool(reposByKey[key] != nil),
                "linkedPR": linked.map { .int($0.number) } ?? .null
            ])
        })
    }

    // MARK: - Repositories

    private static var repos: [ControlAction] {
        let repoParam = Param("repo", .string, "owner/name, or the repo's id.")
        return [
            ControlAction(
                name: "repo.add", summary: "Track a GitHub repository.", scope: .full,
                params: [
                    Param("repo", .string, "owner/name or a github.com URL."),
                    Param("localPath", .string, "An existing clone on this Mac.", required: false)
                ]
            ) { params, context in
                try await ControlEncoding.repo(RepoActions.add(
                    params.string("repo"), localPath: params.optionalString("localPath"), services: context.services
                ))
            },
            ControlAction(
                name: "repo.remove", summary: "Stop tracking a repository; its synced issues and PRs go too.",
                scope: .full, params: [repoParam]
            ) { params, context in
                let repo = try ControlEncoding.repo(named: params.string("repo"), services: context.services)
                try RepoActions.remove(id: repo.id ?? 0, services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "repo.setLocalPath", summary: "Point a repository at its existing clone on this Mac.",
                scope: .full, params: [repoParam, Param("path", .string, "The clone's folder.")]
            ) { params, context in
                let repo = try ControlEncoding.repo(named: params.string("repo"), services: context.services)
                try RepoActions.setLocalPath(id: repo.id ?? 0, path: params.string("path"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "repo.setPRRepo",
                summary: "Set the tracked repository a repository's PRs live in, for tab_linkPR. Leave prRepo out for itself.",
                scope: .full,
                params: [
                    repoParam,
                    Param("prRepo", .string, "owner/name of another tracked repository.", required: false)
                ]
            ) { params, context in
                let repo = try ControlEncoding.repo(named: params.string("repo"), services: context.services)
                let target = try params.optionalString("prRepo").map {
                    try ControlEncoding.repo(named: $0, services: context.services)
                }
                try RepoActions.setPRRepo(id: repo.id ?? 0, prRepoID: target?.id, services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "repo.clone", summary: "Clone a repository with gh and use the clone for its tabs.",
                scope: .full,
                params: [
                    repoParam,
                    Param("path", .string, "Where the clone goes. Default: next to the other clones.", required: false)
                ]
            ) { params, context in
                let repo = try ControlEncoding.repo(named: params.string("repo"), services: context.services)
                return try await .string(RepoActions.clone(
                    id: repo.id ?? 0, to: params.optionalString("path"), services: context.services
                ))
            }
        ]
    }

    // MARK: - Agents

    private static var agents: [ControlAction] {
        let agentName = Param("agent", .string, "The agent's name or id.")
        return [
            ControlAction(
                name: "agent.add", summary: "Add a coding agent profile.", scope: .full,
                params: [
                    Param("name", .string, "Shown on tabs."),
                    Param("command", .string, "The program, e.g. claude."),
                    Param("args", .strings, "Its arguments.", required: false),
                    Param("env", .dictionary, "Extra environment variables.", required: false)
                ]
            ) { params, context in
                try ControlEncoding.agent(AgentActions.add(
                    name: params.string("name"), command: params.string("command"),
                    args: params.strings("args") ?? [], env: params.dictionary("env") ?? [:],
                    services: context.services
                ))
            },
            ControlAction(
                name: "agent.update", summary: "Change an agent profile; only what's given changes.", scope: .full,
                params: [
                    agentName,
                    Param("name", .string, "New name.", required: false),
                    Param("command", .string, "New program.", required: false),
                    Param("args", .strings, "New arguments, replacing the old.", required: false),
                    Param("env", .dictionary, "New environment, replacing the old.", required: false)
                ]
            ) { params, context in
                let agent = try ControlEncoding.agent(named: params.string("agent"), services: context.services)
                try AgentActions.update(
                    id: agent.id ?? 0, name: params.optionalString("name"), command: params.optionalString("command"),
                    args: params.strings("args"), env: params.dictionary("env"), services: context.services
                )
                return .bool(true)
            },
            ControlAction(
                name: "agent.remove", summary: "Remove an agent profile (not the default).", scope: .full,
                params: [agentName]
            ) { params, context in
                let agent = try ControlEncoding.agent(named: params.string("agent"), services: context.services)
                try AgentActions.remove(id: agent.id ?? 0, services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "agent.setDefault", summary: "Make an agent the default for new tabs.", scope: .full,
                params: [agentName]
            ) { params, context in
                let agent = try ControlEncoding.agent(named: params.string("agent"), services: context.services)
                try AgentActions.setDefault(id: agent.id ?? 0, services: context.services)
                return .bool(true)
            }
        ]
    }

    // MARK: - Hosts

    private static var hosts: [ControlAction] {
        let hostName = Param("host", .string, "The host's name or id.")
        return [
            ControlAction(
                name: "host.add", summary: "Add an ssh host tabs can run on.", scope: .full,
                params: [
                    Param("name", .string, "Shown on tabs."),
                    Param("sshTarget", .string, "An ~/.ssh/config alias or user@host."),
                    Param("reposRoot", .string, "Absolute folder on the host where repos are cloned.")
                ]
            ) { params, context in
                let host = try HostActions.add(
                    name: params.string("name"), sshTarget: params.string("sshTarget"),
                    reposRoot: params.string("reposRoot"), services: context.services
                )
                return ControlEncoding.host(host, isDefault: false)
            },
            ControlAction(
                name: "host.update", summary: "Change a host; only what's given changes.", scope: .full,
                params: [
                    hostName,
                    Param("name", .string, "New name.", required: false),
                    Param("sshTarget", .string, "New ssh target.", required: false),
                    Param("reposRoot", .string, "New repos folder.", required: false)
                ]
            ) { params, context in
                let host = try requireHost(params.string("host"), context.services)
                try HostActions.update(
                    id: host.id ?? 0, name: params.optionalString("name"),
                    sshTarget: params.optionalString("sshTarget"),
                    reposRoot: params.optionalString("reposRoot"), services: context.services
                )
                return .bool(true)
            },
            ControlAction(
                name: "host.remove", summary: "Remove a host no tab runs on.", scope: .full, params: [hostName]
            ) { params, context in
                let host = try requireHost(params.string("host"), context.services)
                try HostActions.remove(id: host.id ?? 0, services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "host.check",
                summary: "Check Connection: reach the host, look for the tools tabs need, install or update its helper.",
                scope: .full, params: [hostName]
            ) { params, context in
                let host = try requireHost(params.string("host"), context.services)
                let report = try await HostActions.check(id: host.id ?? 0, services: context.services)
                return .object([
                    "ready": .bool(report.isReady),
                    "missingTools": .array(report.missingTools.map(JSONValue.string)),
                    "helperInstalled": .bool(report.helperInstalled)
                ])
            },
            ControlAction(
                name: "host.setCheckoutPath", summary: "Where a repository's checkout lives on a host.", scope: .full,
                params: [
                    hostName,
                    Param("repo", .string, "owner/name, or the repo's id."),
                    Param("path", .string, "Absolute path on the host.")
                ]
            ) { params, context in
                let host = try requireHost(params.string("host"), context.services)
                let repo = try ControlEncoding.repo(named: params.string("repo"), services: context.services)
                try HostActions.setCheckoutPath(
                    hostID: host.id ?? 0, repoID: repo.id ?? 0, path: params.string("path"), services: context.services
                )
                return .bool(true)
            }
        ]
    }

    private static func requireHost(_ value: String, _ services: AppServices) throws -> RemoteHost {
        guard let host = try ControlEncoding.host(named: value, services: services) else {
            throw ActionError.invalidArgument("host")
        }
        return host
    }

    // MARK: - App

    private static var app: [ControlAction] {
        [
            ControlAction(name: "sync.now", summary: "Sync with GitHub now.", scope: .full, params: []) { _, context in
                try await SyncActions.syncNow(services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "settings.set", summary: "Change General settings; only what's given changes.", scope: .full,
                params: [
                    Param("theme", .string, "App theme.", required: false, choices: ["auto", "light", "dark"]),
                    Param(
                        "terminalTheme",
                        .string,
                        "Terminal theme.",
                        required: false,
                        choices: ["auto", "light", "dark"]
                    ),
                    Param("groupByRepo", .boolean, "Group tabs by repository.", required: false),
                    Param("defaultHost", .string, "Where new tabs run: `local` or a host's name.", required: false),
                    Param("syncSeconds", .integer, "GitHub sync interval, 15–600.", required: false),
                    Param("statusProbeSeconds", .integer, "Git status interval, 2–60.", required: false),
                    Param(
                        "restoreIntervalDefaults",
                        .boolean,
                        "Put both intervals back to their defaults.",
                        required: false
                    )
                ]
            ) { params, context in
                try await setSettings(params, services: context.services)
            },
            ControlAction(
                name: "app.checkForUpdates", summary: "Check for a new Yggdrasil version (shows the updater).",
                scope: .full, params: []
            ) { _, _ in
                UpdaterController.current?.checkForUpdates()
                return .bool(UpdaterController.current != nil)
            },
            ControlAction(
                name: "app.revealCrashLogs", summary: "Show Yggdrasil's crash log folder in Finder.", scope: .full,
                params: []
            ) { _, _ in
                AppActions.revealCrashLogs()
                return .bool(true)
            },
            ControlAction(name: "app.quit", summary: "Quit Yggdrasil.", scope: .full, params: []) { _, _ in
                // After this reply has gone out.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { AppActions.quit() }
                return .bool(true)
            }
        ]
    }

    private static func setSettings(_ params: ActionParams, services: AppServices) async throws -> JSONValue {
        if let raw = params.optionalString("theme"), let mode = AppearanceSettings.Mode(rawValue: raw) {
            SettingsActions.setTheme(mode, services: services)
        }
        if let raw = params.optionalString("terminalTheme"),
           let theme = AppearanceSettings.TerminalTheme(rawValue: raw) {
            SettingsActions.setTerminalTheme(theme)
        }
        if let group = params.optionalBool("groupByRepo") {
            SettingsActions.setGroupByRepo(group, services: services)
        }
        if let value = params.optionalString("defaultHost") {
            try SettingsActions.setDefaultHost(
                id: ControlEncoding.host(named: value, services: services)?.id, services: services
            )
        }
        if params.bool("restoreIntervalDefaults", default: false) {
            try await SettingsActions.setIntervals(
                syncSeconds: IntervalSettings.defaults.syncSeconds,
                statusProbeSeconds: IntervalSettings.defaults.statusProbeSeconds, services: services
            )
        } else if params.optionalInt("syncSeconds") != nil || params.optionalInt("statusProbeSeconds") != nil {
            try await SettingsActions.setIntervals(
                syncSeconds: params.optionalInt("syncSeconds").map(Int.init),
                statusProbeSeconds: params.optionalInt("statusProbeSeconds").map(Int.init), services: services
            )
        }
        return ControlEncoding.settings(SettingsActions.read(services: services))
    }
}

// swiftlint:enable type_body_length
