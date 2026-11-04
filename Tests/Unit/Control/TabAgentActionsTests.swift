import XCTest
@testable import Yggdrasil

/// Starting, typing into and reading a tab's agent without the UI.
@MainActor
final class TabAgentActionsTests: XCTestCase {
    private var services: AppServices!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        suiteName = "TabAgentActionsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        await services.worktreePreparer.drain()
        defaults.removePersistentDomain(forName: suiteName)
        services = nil
    }

    func testStartNeedsAReadyTab() throws {
        services.sessions.hasMainWindow = true
        let tabID = try addTab(state: .preparing)
        XCTAssertThrowsError(try TabActions.start(tabID: tabID, services: services, defaults: defaults)) { error in
            XCTAssertEqual(error as? ActionError, .tabNotReady)
        }
    }

    func testStartNeedsTheMainWindow() throws {
        let tabID = try addTab()
        XCTAssertThrowsError(try TabActions.start(tabID: tabID, services: services, defaults: defaults)) { error in
            XCTAssertEqual(error as? ActionError, .noMainWindow)
        }
    }

    func testStartMountsTheTabWithItsAgentPaneButLeavesTheSelection() throws {
        services.sessions.hasMainWindow = true
        let first = try addTab()
        let second = try addTab()
        let tab = try XCTUnwrap(services.tabStore.get(id: second))
        PaneLayout.split(.diff, .github).persist(for: tab, defaults: defaults)

        try TabActions.start(tabID: second, services: services, defaults: defaults)

        XCTAssertTrue(services.sessions.isOpened(tabID: second))
        XCTAssertEqual(services.tabs.selectedID, first)
        XCTAssertEqual(PaneLayout.load(for: tab, defaults: defaults), .split(.agent, .github))
    }

    func testStartWontReopenAnAgentPaneTheUserClosed() throws {
        services.sessions.hasMainWindow = true
        let tabID = try addTab()
        let tab = try XCTUnwrap(services.tabStore.get(id: tabID))
        PaneLayout.solo(.github).persist(for: tab, defaults: defaults)
        services.sessions.markOpened(tabID: tabID)
        XCTAssertThrowsError(try TabActions.start(tabID: tabID, services: services, defaults: defaults)) { error in
            XCTAssertEqual(error as? ActionError, .agentPaneHidden)
        }
    }

    func testStartRestartsAnOpenTabWhoseAgentWasStopped() async throws {
        services.sessions.hasMainWindow = true
        let agentID = try XCTUnwrap(services.agentStore.getDefault()?.id)
        let tab = try services.tabStore.insert(branchName: "b", worktreePath: "/w", agentID: agentID, taskID: nil)
        services.tabs.reload()
        let tabID = try XCTUnwrap(tab.id)
        PaneLayout.solo(.agent).persist(for: tab, defaults: defaults)
        services.sessions.markOpened(tabID: tabID)
        try await TabActions.terminate(tabID: tabID, services: services)

        try TabActions.start(tabID: tabID, services: services, defaults: defaults)

        // Suspending, not spinning the run loop: this test is itself a job on
        // the main queue, and the respawn is queued behind it.
        let deadline = Date().addingTimeInterval(2)
        while services.sessions.sessions.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(services.sessions.sessions.map(\.id), [tabID])
    }

    func testASecondStartBeforeThePaneAppearsDoesNothing() throws {
        // The pane spawns the agent when it first appears; until then the
        // tab has no session row, and that isn't a stopped agent.
        services.sessions.hasMainWindow = true
        let agentID = try XCTUnwrap(services.agentStore.getDefault()?.id)
        let tab = try services.tabStore.insert(branchName: "b", worktreePath: "/w", agentID: agentID, taskID: nil)
        services.tabs.reload()
        let tabID = try XCTUnwrap(tab.id)
        services.sessions.setPrompt("hello", tabID: tabID)

        try TabActions.start(tabID: tabID, services: services, defaults: defaults)
        try TabActions.start(tabID: tabID, services: services, defaults: defaults)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertTrue(services.sessions.sessions.isEmpty, "left for the pane to spawn")
        XCTAssertEqual(services.sessions.takePrompt(tabID: tabID), "hello")
    }

    func testAnAdHocTabIsntRunningUntilItsTerminalIs() throws {
        let tabID = try TabActions.openAdHoc(
            path: "/tmp", agent: XCTUnwrap(services.agentStore.getDefault()), select: false, services: services
        )
        let tab = try TabActions.tab(tabID, services)
        XCTAssertEqual(ControlEncoding.tab(tab, services: services)["running"], .bool(false))
        services.sessions.registerTerminal(DroppableTerminalView(frame: .zero), tabID: tabID)
        XCTAssertEqual(ControlEncoding.tab(tab, services: services)["running"], .bool(true))
    }

    func testSendAndScreenNeedAMountedTerminal() async throws {
        let tabID = try addTab()
        do {
            try await TabActions.send(tabID: tabID, text: "hi", submit: true, services: services)
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? ActionError, .notRunning)
        }
        XCTAssertThrowsError(try TabActions.screen(tabID: tabID, scrollback: 0, services: services)) { error in
            XCTAssertEqual(error as? ActionError, .notRunning)
        }
    }

    func testScreenReadsTheRegisteredTerminal() throws {
        let tabID = try addTab()
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        services.sessions.registerTerminal(view, tabID: tabID)
        view.feed(text: "ready")
        XCTAssertEqual(try TabActions.screen(tabID: tabID, scrollback: 0, services: services).lines.first, "ready")
    }

    func testAPromptNeedsAClaudeAgent() async throws {
        let repo = try addRepo()
        let codex = try AgentActions.add(name: "Codex", command: "codex", args: [], services: services)
        do {
            _ = try await TabActions.open(
                .init(repo: repo, branchInput: "x", baseBranch: nil, host: nil, agent: codex, prompt: "go"),
                services: services
            )
            XCTFail("expected promptNeedsClaude")
        } catch {
            XCTAssertEqual(error as? ActionError, .promptNeedsClaude)
        }
        XCTAssertTrue(services.tabs.tabs.isEmpty)
    }

    func testThePromptWaitsForTheAgentsFirstStart() async throws {
        let repo = try addRepo()
        let claude = try XCTUnwrap(services.agentStore.getDefault())
        let tabID = try await TabActions.open(
            .init(repo: repo, branchInput: "x", baseBranch: nil, host: nil, agent: claude, prompt: "fix the build"),
            services: services
        )
        XCTAssertEqual(services.sessions.takePrompt(tabID: tabID), "fix the build")
        XCTAssertNil(services.sessions.takePrompt(tabID: tabID), "taken once")
    }

    private func addRepo() throws -> Repo {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agent-actions-\(UUID().uuidString)")
            .path
        return try services.database.queue.write { db -> Repo in
            var repo = Repo(
                id: nil,
                owner: "acme",
                name: "widget",
                defaultBranch: "main",
                localMainPath: path,
                addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
    }

    private func addTab(state: YggdrasilTab.PreparationState = .ready) throws -> Int64 {
        let tab = try services.tabStore.insert(
            branchName: "b\(UUID().uuidString.prefix(4))", worktreePath: "/w", agentID: nil, taskID: nil,
            preparationState: state
        )
        services.tabs.reload()
        return try XCTUnwrap(tab.id)
    }
}
