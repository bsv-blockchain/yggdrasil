import AppKit
import GRDB

/// NSAlert-based input prompts used by the "Coding" menu (`DebugMenu`).
/// Split off into its own file to keep the menu file under SwiftLint's
/// type_body_length cap; behaviour is identical to the inline versions
/// these replaced.
extension DebugMenu {

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
