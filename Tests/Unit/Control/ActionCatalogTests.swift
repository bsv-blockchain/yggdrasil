import XCTest
@testable import Yggdrasil

/// Everything a user can do in the app is in the control API: this list
/// comes from a sweep of every menu, context menu, sheet, picker and Settings
/// pane. A new user action belongs here and in `ActionCatalog`.
@MainActor
final class ActionCatalogTests: XCTestCase {
    private static let userActions: Set<String> = [
        // Reading what the sidebar, badges, pickers and terminals show.
        "state.get", "tabs.list", "tabs.get", "tab.screen", "tab.subagents",
        "reviews.list", "tasks.list", "issues.list", "diagnostics.get",
        // New Session sheet, Assigned Tasks / Review Requests, My Issues, Coding ▸ New Session.
        "tab.open", "tab.openTask", "tab.openIssue", "tab.openAdHoc",
        // Selecting a tab, ⌘⇧[ ], and starting its agent the way selecting does.
        "tab.select", "tab.selectRelative", "tab.start",
        // Typing into the agent; clicking a subagent under a tab.
        "tab.send", "tab.subagentTranscript",
        // Row context menu.
        "tab.restart", "tab.shell", "tab.terminate", "tab.close", "tab.move",
        "tab.linkPR", "tab.unlinkPR", "tab.mute", "tab.unmute", "tab.retrySetup",
        "tab.openInFinder", "tab.openInTerminal",
        // Dragging rows; the pane header; the diff toolbar.
        "tab.reorder", "tab.setLayout", "tab.reloadGitHub", "tab.setDiffScope",
        // Settings → Repositories, Coding ▸ Add/Remove Tracked Repo, onboarding.
        "repo.add", "repo.remove", "repo.setLocalPath", "repo.clone", "repo.setPRRepo",
        // Settings → Agents, Coding ▸ agent items.
        "agent.add", "agent.update", "agent.remove", "agent.setDefault",
        // Settings → Hosts.
        "host.add", "host.update", "host.remove", "host.check", "host.setCheckoutPath",
        // Sync buttons, Settings → General, theme button, Check for Updates, Help menu, Quit.
        "sync.now", "settings.set", "app.checkForUpdates", "app.revealCrashLogs", "app.quit"
    ]

    func testEveryUserActionIsInTheCatalogue() {
        let names = ActionCatalog.all.map(\.name)
        XCTAssertEqual(Set(names), Self.userActions)
        XCTAssertEqual(names.count, Set(names).count, "names are unique")
    }

    func testSendCanTypeKeystrokesInsteadOfPasting() throws {
        let send = try XCTUnwrap(ActionCatalog.all.first { $0.name == "tab.send" })
        XCTAssertNoThrow(try send.validate(["tab": .int(1), "text": .string("2"), "paste": .bool(false)]))
    }

    func testLinkPRTakesWhatTheDialogTakes() throws {
        // A number in the tab's PR repo, a PR URL, or owner/repo#N.
        let link = try XCTUnwrap(ActionCatalog.all.first { $0.name == "tab.linkPR" })
        XCTAssertNoThrow(try link.validate(["tab": .int(1), "pr": .string("acme/code#3")]))
        XCTAssertThrowsError(try link.validate(["tab": .int(1), "number": .int(3)]))
        XCTAssertEqual(ActionError.repoNotTracked("a/b").reason, "repo_not_tracked")
    }

    func testThePRRepoCanBeSetAndCleared() async throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        let issues = try await RepoActions.add("acme/issues", defaultBranch: "main", services: services)
        let code = try await RepoActions.add("acme/code", defaultBranch: "main", services: services)
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.name == "repo.setPRRepo" })
        let context = ControlAction.Context(services: services, key: nil)
        _ = try await action.run(
            action.validate(["repo": .string("acme/issues"), "prRepo": .string("acme/code")]),
            context
        )
        let row = try await services.database.queue.read { db in try Repo.fetchOne(db, key: issues.id) }
        XCTAssertEqual(row?.prRepoID, code.id)
        _ = try await action.run(action.validate(["repo": .string("acme/issues")]), context)
        let cleared = try await services.database.queue.read { db in try Repo.fetchOne(db, key: issues.id) }
        XCTAssertNil(cleared?.prRepoID)
    }

    func testExitCodesAreTheProcessesOwn() {
        // The terminal reports the raw wait status.
        XCTAssertEqual(ControlEncoding.exitStatus(0), 0)
        XCTAssertEqual(ControlEncoding.exitStatus(256), 1)
        XCTAssertEqual(ControlEncoding.exitStatus(15), 143, "killed by SIGTERM")
        XCTAssertEqual(ControlEncoding.exitStatus(-1), -1, "unknown")
    }

    func testOnlyReadingIsAllowedToAReadKey() {
        let reading = Set(ActionCatalog.all.filter { $0.scope == .read }.map(\.name))
        XCTAssertEqual(reading, [
            "state.get", "tabs.list", "tabs.get", "tab.screen", "tab.subagents", "reviews.list", "tasks.list",
            "issues.list", "diagnostics.get"
        ])
    }

    func testToolNamesAreValidForMCP() {
        for action in ActionCatalog.all {
            XCTAssertNotNil(
                action.toolName.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression), action.toolName
            )
            XCTAssertFalse(action.summary.isEmpty, action.name)
        }
    }

    func testTabsListAndOpenThroughTheCatalogue() async throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("catalogue-\(UUID().uuidString)").path
        _ = try await RepoActions.add("acme/widget", defaultBranch: "main", services: services)
        let repo = try ControlEncoding.repo(named: "ACME/Widget", services: services)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        try RepoActions.setLocalPath(id: XCTUnwrap(repo.id), path: path, services: services)

        let opened = try await run("tab.open", ["repo": .string("acme/widget"), "branch": .string("fix")], services)
        let tabID = try XCTUnwrap(opened.intValue)
        let tabs = try await run("tabs.list", [:], services)
        guard case let .array(rows) = tabs, let row = rows.first else { return XCTFail("no tabs") }
        XCTAssertEqual(row["id"], .int(tabID))
        XCTAssertEqual(row["repo"], .string("acme/widget"))
        XCTAssertEqual(row["branch"], .string("claude-fix"))
        XCTAssertEqual(row["agent"], .string("Claude"))
        XCTAssertEqual(row["selected"], .bool(true), "the only tab is selected anyway")
        await services.worktreePreparer.drain()
        try? FileManager.default.removeItem(atPath: path)
    }

    func testARunningTabsSubagents() async throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        let tab = try services.tabStore.insert(branchName: "b", worktreePath: "/w", agentID: nil, taskID: nil)
        services.tabs.reload()
        let tabID = try XCTUnwrap(tab.id)
        let explore = SubagentInfo(
            agentID: "a1", agentType: "Explore", description: "Find tests", spawnDepth: 1, background: true,
            lastWrite: Date(timeIntervalSince1970: 0), transcriptPath: "/nowhere/agent-a1.jsonl"
        )
        services.subagents.set([explore], forTabID: tabID)

        let idle = try await run("tab.subagents", ["tab": .int(tabID)], services)
        XCTAssertEqual(idle, .array([]), "its agent isn't running, so neither are they")

        let terminal = DroppableTerminalView(frame: .zero)
        services.sessions.registerTerminal(terminal, tabID: tabID)
        let listed = try await run("tab.subagents", ["tab": .int(tabID)], services)
        guard case let .array(rows) = listed, let row = rows.first else { return XCTFail("\(listed)") }
        XCTAssertEqual(row["id"], .string("a1"))
        XCTAssertEqual(row["type"], .string("Explore"))
        XCTAssertEqual(row["background"], .bool(true))
        let tabRow = try await run("tabs.get", ["tab": .int(tabID)], services)
        XCTAssertEqual(tabRow["runningSubagents"], .int(1))
        // Its tool output can hold anything a command printed: full keys only.
        let transcript = try XCTUnwrap(ActionCatalog.all.first { $0.name == "tab.subagentTranscript" })
        XCTAssertEqual(transcript.scope, .full)
    }

    func testThePinnedSessionIsNotATabToTheAPI() async throws {
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        let dataDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalogue-\(UUID().uuidString)")
        let manager = try ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory)
        try services.tabs.select(XCTUnwrap(manager.id))

        let tabs = try await run("tabs.list", [:], services)
        XCTAssertEqual(tabs, .array([]))
        let state = try await run("state.get", [:], services)
        XCTAssertEqual(state["selectedTab"], .null)
        do {
            _ = try await run("tab.close", ["tab": .int(XCTUnwrap(manager.id))], services)
            XCTFail("closed the pinned session")
        } catch {
            XCTAssertEqual(error as? ActionError, try .unknownTab(XCTUnwrap(manager.id)))
        }
        do {
            _ = try await run("tab.unlinkPR", ["tab": .int(XCTUnwrap(manager.id))], services)
            XCTFail("unlinked on the pinned session")
        } catch {
            XCTAssertEqual(error as? ActionError, try .unknownTab(XCTUnwrap(manager.id)))
        }
    }

    func testAgentArgumentsAreForFullKeysOnly() async throws {
        // A profile's arguments can hold a token, like its environment can.
        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        try AgentActions.add(name: "Grok", command: "grok", args: ["--api-key", "xai-secret"], services: services)
        let read = APIKey(id: 1, name: "r", scope: .read, sha256: "", createdAt: Date(), lastUsedAt: nil)
        let full = APIKey(id: 2, name: "f", scope: .full, sha256: "", createdAt: Date(), lastUsedAt: nil)

        let seenByRead = try await run("state.get", [:], services, key: read)
        XCTAssertFalse(seenByRead.jsonText.contains("xai-secret"))
        let seenByFull = try await run("state.get", [:], services, key: full)
        XCTAssertTrue(seenByFull.jsonText.contains("xai-secret"))
    }

    private func run(
        _ name: String, _ arguments: [String: JSONValue], _ services: AppServices, key: APIKey? = nil
    ) async throws -> JSONValue {
        let action = try XCTUnwrap(ActionCatalog.all.first { $0.name == name })
        return try await action.run(action.validate(arguments), .init(services: services, key: key))
    }
}
