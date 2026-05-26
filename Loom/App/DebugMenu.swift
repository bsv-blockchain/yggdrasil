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
        }
    }

    // MARK: - Handlers

    private func handleAddTrackedRepo() {
        guard let database = services?.database else {
            LoomLog.ui.warning("AddTrackedRepo: no services available (running under tests?)")
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
            LoomLog.ui.info("Added tracked repo \(owner)/\(name)")
        } catch {
            LoomLog.ui.error("Failed to add tracked repo: \(String(describing: error), privacy: .public)")
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
            LoomLog.ui.info("Removed tracked repo \(selected.fullName)")
        } catch {
            LoomLog.ui.error("Failed to remove tracked repo: \(String(describing: error), privacy: .public)")
        }
    }

    private func handleForceSync() {
        guard let sync = services?.syncService else { return }
        Task {
            do {
                try await sync.fullSync()
            } catch {
                LoomLog.ui.error("Force sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func handleDumpTasks() {
        guard let database = services?.database else { return }
        do {
            let tasks = try database.queue.read { db in try LoomTask.fetchAll(db) }
            LoomLog.ui.info("Dumping \(tasks.count, privacy: .public) tasks:")
            for task in tasks {
                LoomLog.ui.info(
                    """
                    [\(task.type.rawValue, privacy: .public)] #\(task.number, privacy: .public) \
                    title=\(task.title, privacy: .public) state=\(task.state.rawValue, privacy: .public)
                    """
                )
            }
        } catch {
            LoomLog.ui.error("Dump failed: \(String(describing: error), privacy: .public)")
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

    static func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
