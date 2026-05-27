import AppKit
import GRDB
import SwiftUI

/// Top-level "Coding" menu — tracked-repo / agent / session management. Was
/// "Debug" earlier but every item here is part of the normal workflow, not
/// debug-only, so the name lied. Wired in Phase 1 to the `AppServices` graph
/// the AppDelegate built at launch.
struct DebugMenu: Commands {
    /// Pulled fresh on every menu click to dodge passing the live AppDelegate
    /// reference through SwiftUI's environment.
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some Commands {
        CommandMenu("Coding") {
            Button("Add Tracked Repo…") {
                YggdrasilLog.ui.info("Coding menu: Add Tracked Repo clicked")
                handleAddTrackedRepo()
            }
            .keyboardShortcut("R", modifiers: [.command, .shift])

            Button("Remove Tracked Repo…") {
                handleRemoveTrackedRepo()
            }

            Divider()

            Button("Force Sync Now") {
                handleForceSync()
            }
            .keyboardShortcut("S", modifiers: [.command, .shift])

            Button("Dump Tasks to Log") {
                handleDumpTasks()
            }

            Divider()

            Button("Add Agent…") {
                handleAddAgent()
            }
            Button("Remove Agent…") {
                handleRemoveAgent()
            }
            Button("Set Default Agent…") {
                handleSetDefaultAgent()
            }

            Divider()

            Button("+ New Session…") {
                handleNewSession()
            }
            .keyboardShortcut("N", modifiers: [.command, .shift])
        }
    }

    // MARK: - Handlers

    private func handleAddTrackedRepo() {
        YggdrasilLog.ui.info("Coding menu: handleAddTrackedRepo entered")
        guard let database = services?.database else {
            YggdrasilLog.ui.warning("AddTrackedRepo: no services available (running under tests?)")
            return
        }
        guard let (owner, name) = DebugMenu.promptForOwnerAndName() else { return }
        do {
            try database.queue.write { db in
                var repo = Repo(
                    id: nil, owner: owner, name: name, defaultBranch: "main",
                    localMainPath: nil, addedAt: Date()
                )
                try repo.insert(db)
            }
            YggdrasilLog.ui.info("Added tracked repo \(owner)/\(name)")
        } catch {
            YggdrasilLog.ui.error("Failed to add tracked repo: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleRemoveTrackedRepo() {
        YggdrasilLog.ui.info("Coding menu: handleRemoveTrackedRepo entered")
        guard let database = services?.database else {
            YggdrasilLog.ui.warning("RemoveTrackedRepo: no services available")
            return
        }
        do {
            let repos = try database.queue.read { db in try Repo.fetchAll(db) }
            guard !repos.isEmpty else {
                DebugMenu.alert(title: "No tracked repos", message: "Use “Add Tracked Repo…” first.")
                return
            }
            guard let selected = DebugMenu.promptForRepoChoice(repos) else { return }
            try database.queue.write { db in try selected.delete(db) }
            YggdrasilLog.ui.info("Removed tracked repo \(selected.fullName)")
        } catch {
            YggdrasilLog.ui.error("Failed to remove tracked repo: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleForceSync() {
        YggdrasilLog.ui.info("Coding menu: handleForceSync entered")
        guard let sync = services?.syncService else {
            YggdrasilLog.ui.warning("ForceSync: no services available")
            return
        }
        Task {
            do {
                try await sync.fullSync()
            } catch {
                YggdrasilLog.ui.error("Force sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handleDumpTasks() {
        YggdrasilLog.ui.info("Coding menu: handleDumpTasks entered")
        guard let database = services?.database else {
            YggdrasilLog.ui.warning("DumpTasks: no services available")
            return
        }
        do {
            let tasks = try database.queue.read { db in try YggdrasilTask.fetchAll(db) }
            YggdrasilLog.ui.info("Dumping \(tasks.count, privacy: .public) tasks:")
            for task in tasks {
                YggdrasilLog.ui.info(
                    """
                    [\(task.type.rawValue, privacy: .public)] #\(task.number, privacy: .public) \
                    title=\(task.title, privacy: .public) state=\(task.state.rawValue, privacy: .public)
                    """
                )
            }
        } catch {
            YggdrasilLog.ui.error("Dump failed: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Agent handlers

    private func handleAddAgent() {
        YggdrasilLog.ui.info("Coding menu: handleAddAgent entered")
        guard let store = services?.agentStore else {
            YggdrasilLog.ui.warning("AddAgent: no services available")
            return
        }
        guard let details = DebugMenu.promptForAgentDetails() else { return }
        do {
            _ = try store.add(name: details.name, command: details.command, args: details.args)
            // No mutation needed beyond store call; refresh isn't displayed in Phase 3.
            YggdrasilLog.ui.info("Added coding agent \(details.name, privacy: .public)")
        } catch {
            DebugMenu.alert(title: "Add agent failed", message: String(describing: error))
        }
    }

    private func handleRemoveAgent() {
        YggdrasilLog.ui.info("Coding menu: handleRemoveAgent entered")
        guard let store = services?.agentStore else {
            YggdrasilLog.ui.warning("RemoveAgent: no services available")
            return
        }
        do {
            let agents = try store.list()
            guard !agents.isEmpty else {
                DebugMenu.alert(title: "No agents", message: "Use “Add Agent…” first.")
                return
            }
            guard let picked = DebugMenu.promptForAgentChoice(agents, title: "Remove Agent") else { return }
            try store.remove(id: picked.id!)
            YggdrasilLog.ui.info("Removed coding agent \(picked.name, privacy: .public)")
        } catch {
            DebugMenu.alert(title: "Remove agent failed", message: String(describing: error))
        }
    }

    private func handleSetDefaultAgent() {
        YggdrasilLog.ui.info("Coding menu: handleSetDefaultAgent entered")
        guard let store = services?.agentStore else {
            YggdrasilLog.ui.warning("SetDefaultAgent: no services available")
            return
        }
        do {
            let agents = try store.list()
            guard !agents.isEmpty else {
                DebugMenu.alert(title: "No agents", message: "Use “Add Agent…” first.")
                return
            }
            guard let picked = DebugMenu.promptForAgentChoice(agents, title: "Set Default Agent") else { return }
            try store.setDefault(id: picked.id!)
            YggdrasilLog.ui.info("Default coding agent is now \(picked.name, privacy: .public)")
        } catch {
            DebugMenu.alert(title: "Set default failed", message: String(describing: error))
        }
    }

    private func handleNewSession() {
        YggdrasilLog.ui.info("Coding menu: handleNewSession entered")
        guard let services else { return }
        do {
            let agents = try services.agentStore.list()
            guard !agents.isEmpty else {
                DebugMenu.alert(title: "No agents", message: "Add an agent first.")
                return
            }
            guard let pick = DebugMenu.promptForNewSession(agents: agents) else { return }
            let lastComponent = URL(fileURLWithPath: pick.cwd).lastPathComponent
            let newTab = try services.tabStore.insert(
                branchName: "ad-hoc",
                worktreePath: pick.cwd,
                agentID: pick.agent.id,
                taskID: nil
            )
            services.tabs.reload()
            if let tabID = newTab.id {
                services.tabs.select(tabID)
                services.sessions.add(
                    OpenSession(
                        id: tabID,
                        displayName: "\(pick.agent.name) · \(lastComponent)",
                        cwd: pick.cwd,
                        command: pick.agent.command,
                        args: pick.agent.args
                    )
                )
            }
        } catch {
            DebugMenu.alert(title: "New session failed", message: String(describing: error))
        }
    }

}
