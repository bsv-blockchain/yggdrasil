import Foundation

/// Starting, stopping, typing into and reading a tab's agent.
extension TabActions {
    /// Starts the tab's agent (or reattaches it on its host) without
    /// selecting the tab: it runs in its pane, mounted out of sight. An
    /// exited agent is resumed.
    static func start(tabID: Int64, services: AppServices, defaults: UserDefaults = .standard) throws {
        let tab = try tab(tabID, services)
        guard tab.isReady else { throw ActionError.tabNotReady }
        guard !services.sessions.movingTabs.contains(tabID) else { throw ActionError.moveInProgress }
        // Tab panes only exist inside the main window.
        guard services.sessions.hasMainWindow else { throw ActionError.noMainWindow }
        if services.sessions.exitedTabs[tabID] != nil {
            try restart(tabID: tabID, services: services)
            return
        }
        // The agent runs inside the tab's agent pane. A tab that isn't open
        // yet gets one; on an open tab the user closed it, so leave it.
        let layout = PaneLayout.load(for: tab, defaults: defaults)
        if !layout.contains(.agent) {
            guard !services.sessions.isOpened(tabID: tabID) else { throw ActionError.agentPaneHidden }
            layout.with(primary: .agent).persist(for: tab, defaults: defaults)
        }
        // A pane that's already up only starts its agent when it first
        // appears; one stopped since (tab.terminate) has to be started again.
        if services.sessions.stoppedTabs.contains(tabID) {
            try restart(tabID: tabID, services: services)
            return
        }
        services.sessions.markOpened(tabID: tabID)
    }

    /// Resume Session: the agent again, with its conversation.
    static func restart(tabID: Int64, services: AppServices) throws {
        _ = try tab(tabID, services)
        guard !services.sessions.movingTabs.contains(tabID) else { throw ActionError.moveInProgress }
        guard SidebarActions.agentSession(tabID: tabID, services: services) != nil else { throw ActionError.notRunning }
        SidebarActions.restartAgent(tabID: tabID, services: services)
    }

    /// New Shell: a login shell in the tab's worktree in place of the agent.
    static func shell(tabID: Int64, services: AppServices) throws {
        _ = try tab(tabID, services)
        guard !services.sessions.movingTabs.contains(tabID) else { throw ActionError.moveInProgress }
        guard services.sessions.sessions.contains(where: { $0.id == tabID }) else { throw ActionError.notRunning }
        SidebarActions.openShell(tabID: tabID, services: services)
    }

    /// Stops the agent, on its host too. The tab stays.
    static func terminate(tabID: Int64, services: AppServices) async throws {
        let tab = try tab(tabID, services)
        guard !services.sessions.movingTabs.contains(tabID) else { throw ActionError.moveInProgress }
        services.sessions.terminate(tabID: tabID)
        services.sessions.markStopped(tabID: tabID)
        if let host = services.host(for: tab) {
            try await services.remoteControl.kill(host: host, tabID: tabID)
        }
    }

    /// Types `text` into the agent; `submit` then presses Enter.
    static func send(tabID: Int64, text: String, submit: Bool, services: AppServices) async throws {
        _ = try tab(tabID, services)
        guard services.sessions.exitedTabs[tabID] == nil,
              let view = services.sessions.terminal(for: tabID)
        else { throw ActionError.notRunning }
        await TerminalControl.send(text, submit: submit, to: view)
    }

    /// What the agent's terminal shows, plus up to `scrollback` lines above.
    static func screen(tabID: Int64, scrollback: Int, services: AppServices) throws -> TerminalControl.Screen {
        _ = try tab(tabID, services)
        guard let view = services.sessions.terminal(for: tabID) else { throw ActionError.notRunning }
        return TerminalControl.screen(of: view, scrollback: scrollback)
    }

    /// Previous/Next Session.
    static func selectRelative(by delta: Int, services: AppServices) {
        SidebarActions.selectTab(by: delta, services: services)
    }
}
