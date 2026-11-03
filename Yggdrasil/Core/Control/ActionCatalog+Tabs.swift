import AppKit
import Foundation

extension ActionCatalog {
    private typealias Param = ControlAction.Param

    private static let tab = Param("tab", .integer, "The tab's id, from tabs_list.")
    private static let host = Param(
        "host", .string, "`local` for this Mac, or a host's name. Default: the host set for new tabs.", required: false
    )
    private static let agent = Param("agent", .string, "Agent name. Default: the default agent.", required: false)
    private static let prompt = Param(
        "prompt", .string, """
        What the new Claude conversation starts with, once its worktree is ready and it starts. On a host it \
        passes through the command line, so other users of that host can see it in their process list.
        """, required: false
    )
    private static let select = Param(
        "select", .boolean, "Show the new tab in the main window. Default false: what the user sees stays.",
        required: false
    )

    static var tabs: [ControlAction] {
        opening + running + managing + panes
    }

    // MARK: - Opening

    private static var opening: [ControlAction] {
        [
            ControlAction(
                name: "tab.open",
                summary: """
                New Session: a tab on a new or existing branch, in its own worktree. Returns its id; the worktree \
                is built in the background (see `preparation` in tabs_get), then tab_start runs the agent.
                """,
                scope: .full,
                params: [
                    Param("branch", .string, "A branch name, pr-N / issue-N, #N, or a GitHub PR or issue URL."),
                    Param("repo", .string, "owner/name. Optional when branch is a GitHub URL.", required: false),
                    Param(
                        "base",
                        .string,
                        "Branch to start from. Default: the repo's default branch.",
                        required: false
                    ),
                    host, agent, prompt, select,
                    Param(
                        "clone",
                        .boolean,
                        "Clone the repo on this Mac first if it isn't. Default false.",
                        required: false
                    )
                ]
            ) { params, context in
                try await open(params, services: context.services)
            },
            ControlAction(
                name: "tab.openTask",
                summary: "Open a task from reviews_list or tasks_list as a tab, linked to it.",
                scope: .full,
                params: [Param("task", .integer, "The task's id."), host, agent, prompt, select]
            ) { params, context in
                let services = context.services
                let taskID = try params.int("task")
                let (task, repo, toReview) = try await services.database.queue.read { db in
                    try (
                        YggdrasilTask.fetchOne(db, key: taskID),
                        Repo.fetchAll(db),
                        TaskQueries.toReview(db).contains { $0.id == taskID }
                    )
                }
                guard let task, let repo = repo.first(where: { $0.id == task.repoID }) else {
                    throw ActionError.invalidArgument("task")
                }
                return try await .int(TabActions.openTask(
                    task, repo: repo, mode: toReview ? .review : .assigned,
                    host: ControlEncoding.host(named: params.optionalString("host"), services: services),
                    agent: ControlEncoding.agent(named: params.optionalString("agent"), services: services),
                    select: params.bool("select", default: false), prompt: params.optionalString("prompt"),
                    services: services
                ))
            },
            ControlAction(
                name: "tab.openIssue", summary: "Open an issue from issues_list as a tab (My Issues ▸ Open as Tab).",
                scope: .full,
                params: [
                    Param("repo", .string, "owner/name; must be tracked."),
                    Param("number", .integer, "The issue number."),
                    Param("title", .string, "Its title.", required: false),
                    host, agent, select
                ]
            ) { params, context in
                let services = context.services
                let repo = try ControlEncoding.repo(named: params.string("repo"), services: services)
                let number = try params.int("number")
                return try await .int(TabActions.openIssue(
                    number: Int(number), title: params.optionalString("title") ?? "",
                    url: "https://github.com/\(repo.fullName)/issues/\(number)", repo: repo,
                    host: ControlEncoding.host(named: params.optionalString("host"), services: services),
                    agent: ControlEncoding.agent(named: params.optionalString("agent"), services: services),
                    select: params.bool("select", default: false), services: services
                ))
            },
            ControlAction(
                name: "tab.openAdHoc",
                summary: "Coding ▸ New Session: an agent in any folder on this Mac, no worktree.",
                scope: .full, params: [Param("path", .string, "The folder."), agent, select]
            ) { params, context in
                let path = try params.string("path")
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                      isDirectory.boolValue else {
                    throw ActionError.invalidArgument("path")
                }
                return try .int(TabActions.openAdHoc(
                    path: path, agent: ControlEncoding.agent(
                        named: params.optionalString("agent"),
                        services: context.services
                    ),
                    select: params.bool("select", default: false), services: context.services
                ))
            }
        ]
    }

    private static func open(_ params: ActionParams, services: AppServices) async throws -> JSONValue {
        let branch = try params.string("branch")
        let agent = try ControlEncoding.agent(named: params.optionalString("agent"), services: services)
        let slug = params.optionalString("repo")
            ?? TabActions.plan(branchInput: branch, agentName: agent.name, baseBranch: nil).repoSlug
        guard let slug else { throw ActionError.invalidArgument("repo") }
        var repo = try ControlEncoding.repo(named: slug, services: services)
        let host = try ControlEncoding.host(named: params.optionalString("host"), services: services)
        if host == nil, repo.localMainPath == nil, params.bool("clone", default: false) {
            try await RepoActions.clone(id: repo.id ?? 0, services: services)
            repo = try ControlEncoding.repo(named: slug, services: services)
        }
        return try await .int(TabActions.open(
            .init(
                repo: repo, branchInput: branch, baseBranch: params.optionalString("base") ?? repo.defaultBranch,
                host: host, agent: agent, select: params.bool("select", default: false),
                prompt: params.optionalString("prompt")
            ),
            services: services
        ))
    }

    // MARK: - The agent

    private static var running: [ControlAction] {
        [
            ControlAction(
                name: "tab.start",
                summary: "Start (or reattach) the tab's agent without changing what the user sees. Needs the main window.",
                scope: .full, params: [tab]
            ) { params, context in
                try TabActions.start(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.send",
                summary: "Type into the tab's agent; with submit, press Enter after. Read the result with tab_screen.",
                scope: .full,
                params: [
                    tab,
                    Param("text", .string, "What to type. Newlines stay text in a prompt that accepts a paste."),
                    Param("submit", .boolean, "Press Enter after the text. Default true.", required: false)
                ]
            ) { params, context in
                try await TabActions.send(
                    tabID: params.int("tab"), text: params.string("text"), submit: params.bool("submit", default: true),
                    services: context.services
                )
                return .bool(true)
            },
            ControlAction(
                name: "tab.restart", summary: "Resume Session: start the agent again with its conversation.",
                scope: .full, params: [tab]
            ) { params, context in
                try TabActions.restart(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.shell", summary: "New Shell: a shell in the tab's worktree in place of the agent.",
                scope: .full, params: [tab]
            ) { params, context in
                try TabActions.shell(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.terminate", summary: "Stop the tab's agent (on its host too). The tab stays.",
                scope: .full, params: [tab]
            ) { params, context in
                try await TabActions.terminate(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            }
        ]
    }

    // MARK: - Managing

    private static var managing: [ControlAction] {
        [
            ControlAction(
                name: "tab.select", summary: "Show the tab in the main window and bring Yggdrasil to the front.",
                scope: .full, params: [tab]
            ) { params, context in
                try TabActions.select(tabID: params.int("tab"), services: context.services)
                NSApp.activate(ignoringOtherApps: true)
                return .bool(true)
            },
            ControlAction(
                name: "tab.selectRelative", summary: "Previous or Next Session in the sidebar.", scope: .full,
                params: [Param("direction", .string, "Which way.", choices: ["previous", "next"])]
            ) { params, context in
                let delta = try params.string("direction") == "next" ? 1 : -1
                TabActions.selectRelative(by: delta, services: context.services)
                return .optional(context.services.tabs.selectedID)
            },
            ControlAction(
                name: "tab.close",
                summary: "Close the tab and stop its agent. With deleteWorktree, also `git worktree remove --force`, discarding uncommitted work.",
                scope: .full,
                params: [
                    tab,
                    Param("deleteWorktree", .boolean, "Also delete the worktree. Default false.", required: false)
                ]
            ) { params, context in
                let problems = try await TabActions.close(
                    id: params.int("tab"), deleteWorktree: params.bool("deleteWorktree", default: false),
                    services: context.services
                )
                return .object(["problems": .array(problems.map(JSONValue.string))])
            },
            ControlAction(
                name: "tab.move",
                summary: "Move the tab's branch, worktree and conversation between this Mac and a host. Committed work only.",
                scope: .full,
                params: [tab, Param("to", .string, "`local`, or a host's name.")]
            ) { params, context in
                let destination = try ControlEncoding.host(named: params.string("to"), services: context.services)
                return try await .object(["worktree": .string(TabActions.move(
                    tabID: params.int("tab"), to: destination, services: context.services
                ))])
            },
            ControlAction(
                name: "tab.linkPR", summary: "Link a PR of the tab's repository to the tab.", scope: .full,
                params: [tab, Param("number", .integer, "The PR number.")]
            ) { params, context in
                try await TabActions.linkPR(
                    tabID: params.int("tab"), number: Int(params.int("number")), services: context.services
                )
                return .bool(true)
            },
            ControlAction(
                name: "tab.unlinkPR", summary: "Unlink the tab's PR (an issue tab keeps its issue).", scope: .full,
                params: [tab]
            ) { params, context in
                try TabActions.unlinkPR(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.mute", summary: "Mute the tab's attention until something changes.", scope: .full,
                params: [tab]
            ) { params, context in
                try TabActions.mute(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(name: "tab.unmute", summary: "Undo tab_mute.", scope: .full,
                          params: [tab]) { params, context in
                try TabActions.unmute(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.retrySetup", summary: "Build a tab's worktree again after it failed.", scope: .full,
                params: [tab]
            ) { params, context in
                try TabActions.retrySetup(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.reorder", summary: "Move the tab to a position in the sidebar.", scope: .full,
                params: [tab, Param("position", .integer, "0 is the top.")]
            ) { params, context in
                try TabActions.reorder(
                    tabID: params.int("tab"), to: Int(params.int("position")), services: context.services
                )
                return .bool(true)
            }
        ]
    }

    // MARK: - Panes

    private static var panes: [ControlAction] {
        [
            ControlAction(
                name: "tab.setLayout", summary: "Which panes the tab shows.", scope: .full,
                params: [
                    tab,
                    Param(
                        "layout", .string, "Panes, left to right.",
                        choices: ["agent", "github", "diff", "agent+diff", "agent+github", "diff+github"]
                    )
                ]
            ) { params, context in
                try TabActions.setLayout(
                    tabID: params.int("tab"), layout: params.string("layout"), services: context.services
                )
                return .bool(true)
            },
            ControlAction(
                name: "tab.setDiffScope", summary: "What the Diff pane compares.", scope: .full,
                params: [
                    tab,
                    Param(
                        "scope", .string, "`branch`: the branch and uncommitted work; `uncommitted`: only that.",
                        choices: ["branch", "uncommitted"]
                    )
                ]
            ) { params, context in
                try TabActions.setDiffScope(
                    tabID: params.int("tab"), scope: params.string("scope"), services: context.services
                )
                return .bool(true)
            },
            ControlAction(
                name: "tab.reloadGitHub",
                summary: "Reload the tab's GitHub pane.",
                scope: .full,
                params: [tab]
            ) { params, context in
                try TabActions.reloadGitHub(tabID: params.int("tab"), services: context.services)
                return .bool(true)
            },
            ControlAction(
                name: "tab.openInFinder", summary: "Show the worktree of a tab on this Mac in Finder.", scope: .full,
                params: [tab]
            ) { params, context in
                try SidebarActions.openInFinder(path: localWorktree(params.int("tab"), context.services))
                return .bool(true)
            },
            ControlAction(
                name: "tab.openInTerminal", summary: "Open Terminal.app in the worktree of a tab on this Mac.",
                scope: .full, params: [tab]
            ) { params, context in
                try SidebarActions.openInTerminal(path: localWorktree(params.int("tab"), context.services))
                return .bool(true)
            }
        ]
    }

    /// A remote tab's worktree isn't on this Mac.
    private static func localWorktree(_ tabID: Int64, _ services: AppServices) throws -> String {
        let tab = try TabActions.tab(tabID, services)
        guard tab.hostID == nil else { throw ActionError.invalidArgument("tab") }
        return tab.worktreePath
    }
}
