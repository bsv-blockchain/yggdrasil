import AppKit
import GRDB
import SwiftUI

/// Commands installed under a top-level "Debug" menu. Wired in Phase 1 to the
/// `AppServices` graph the AppDelegate built at launch.
struct DebugMenu: Commands {
    /// Pulled fresh on every menu click to dodge passing the live AppDelegate
    /// reference through SwiftUI's environment.
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Add Tracked Repo…") {
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
        guard let database = services?.database else { return }
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
        guard let sync = services?.syncService else { return }
        Task {
            do {
                try await sync.fullSync()
            } catch {
                YggdrasilLog.ui.error("Force sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handleDumpTasks() {
        guard let database = services?.database else { return }
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

    // MARK: - Prompts (NSAlert-based, blocking on the main thread)

    static func promptForOwnerAndName() -> (owner: String, name: String)? {
        let alert = NSAlert()
        alert.messageText = "Add Tracked Repo"
        alert.informativeText = "Enter the GitHub repo as owner/name (e.g. bsv-blockchain/teranode)."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "owner/name"
        alert.accessoryView = field

        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = raw.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            alert.messageText = "Invalid format"
            return nil
        }
        return (parts[0], parts[1])
    }

    static func promptForRepoChoice(_ repos: [Repo]) -> Repo? {
        let alert = NSAlert()
        alert.messageText = "Remove Tracked Repo"
        alert.informativeText = "Pick a repo to remove. All tasks for it will also be deleted."
        alert.alertStyle = .warning

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for repo in repos {
            popup.addItem(withTitle: repo.fullName)
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < repos.count else { return nil }
        return repos[idx]
    }

    // MARK: - Agent handlers

    private func handleAddAgent() {
        guard let store = services?.agentStore else { return }
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
        guard let store = services?.agentStore else { return }
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
        guard let store = services?.agentStore else { return }
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

    // MARK: - Agent prompts

    struct AgentDetails {
        let name: String
        let command: String
        let args: [String]
    }

    static func promptForAgentDetails() -> AgentDetails? {
        let alert = NSAlert()
        alert.messageText = "Add Coding Agent"
        alert.informativeText = "Name, command, and optional space-separated args."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 90))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        nameField.placeholderString = "Name (e.g. Codex)"
        let commandField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        commandField.placeholderString = "Command (e.g. codex)"
        let argsField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        argsField.placeholderString = "Args (space-separated, optional)"
        stack.addArrangedSubview(nameField)
        stack.addArrangedSubview(commandField)
        stack.addArrangedSubview(argsField)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = nameField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = commandField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let argsRaw = argsField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !command.isEmpty else { return nil }
        let args = argsRaw.isEmpty ? [] : argsRaw.split(separator: " ").map(String.init)
        return AgentDetails(name: name, command: command, args: args)
    }

    static func promptForAgentChoice(_ agents: [CodingAgent], title: String) -> CodingAgent? {
        let alert = NSAlert()
        alert.messageText = title
        alert.alertStyle = .informational
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for agent in agents {
            popup.addItem(withTitle: "\(agent.name) (\(agent.command))")
        }
        alert.accessoryView = popup
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx >= 0, idx < agents.count else { return nil }
        return agents[idx]
    }

    static func promptForNewSession(agents: [CodingAgent]) -> (cwd: String, agent: CodingAgent)? {
        let alert = NSAlert()
        alert.messageText = "New Session"
        alert.informativeText = "Worktree (absolute path) and agent profile."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Start")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 360, height: 62))
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let cwdField = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        cwdField.placeholderString = "Worktree path"
        cwdField.stringValue = NSHomeDirectory()
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26))
        let defaultIndex = agents.firstIndex(where: \.isDefault) ?? 0
        for agent in agents {
            popup.addItem(withTitle: "\(agent.name) (\(agent.command))")
        }
        popup.selectItem(at: defaultIndex)
        stack.addArrangedSubview(cwdField)
        stack.addArrangedSubview(popup)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = cwdField

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let cwd = cwdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let idx = popup.indexOfSelectedItem
        guard !cwd.isEmpty, idx >= 0, idx < agents.count else { return nil }
        return (cwd, agents[idx])
    }

    static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
