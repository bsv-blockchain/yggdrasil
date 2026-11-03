import XCTest
@testable import Yggdrasil

/// Everything a user can do in the app is in the control API: this list
/// comes from a sweep of every menu, context menu, sheet, picker and Settings
/// pane. A new user action belongs here and in `ActionCatalog`.
@MainActor
final class ActionCatalogTests: XCTestCase {
    private static let userActions: Set<String> = [
        // Reading what the sidebar, badges, pickers and terminals show.
        "state.get", "tabs.list", "tabs.get", "tab.screen",
        "reviews.list", "tasks.list", "issues.list", "diagnostics.get",
        // New Session sheet, Assigned Tasks / Review Requests, My Issues, Coding ▸ New Session.
        "tab.open", "tab.openTask", "tab.openIssue", "tab.openAdHoc",
        // Selecting a tab, ⌘⇧[ ], and starting its agent the way selecting does.
        "tab.select", "tab.selectRelative", "tab.start",
        // Typing into the agent.
        "tab.send",
        // Row context menu.
        "tab.restart", "tab.shell", "tab.terminate", "tab.close", "tab.move",
        "tab.linkPR", "tab.unlinkPR", "tab.mute", "tab.unmute", "tab.retrySetup",
        "tab.openInFinder", "tab.openInTerminal",
        // Dragging rows; the pane header; the diff toolbar.
        "tab.reorder", "tab.setLayout", "tab.reloadGitHub", "tab.setDiffScope",
        // Settings → Repositories, Coding ▸ Add/Remove Tracked Repo, onboarding.
        "repo.add", "repo.remove", "repo.setLocalPath", "repo.clone",
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

    func testOnlyReadingIsAllowedToAReadKey() {
        let reading = Set(ActionCatalog.all.filter { $0.scope == .read }.map(\.name))
        XCTAssertEqual(reading, [
            "state.get", "tabs.list", "tabs.get", "tab.screen", "reviews.list", "tasks.list", "issues.list",
            "diagnostics.get"
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
