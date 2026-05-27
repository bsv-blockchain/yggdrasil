import AppKit
import Foundation
import GRDB

/// Owns the AppKit "Coding" menu — tracked-repo / agent / session management.
///
/// Previously implemented as a SwiftUI `CommandMenu`; the SwiftUI command
/// system stopped routing the menu items' actions once the app gained a
/// `MenuBarExtra` Scene (a SwiftUI quirk; multiple Scenes confuse menu
/// dispatch). This controller builds the menu via plain AppKit which is
/// rock-solid: NSMenuItem targets self with @objc selectors, no routing
/// indirection.
@MainActor
final class CodingMenuController: NSObject {
    private weak var appDelegate: AppDelegate?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    /// Build the Coding menu and insert it into the main menu bar right after
    /// View (matching where SwiftUI's CommandMenu would normally place a
    /// custom top-level menu).
    /// Identity tag we apply to the inserted NSMenuItem so we can find it
    /// again on later re-install attempts. `view` is 2 and `window` is 100
    /// by convention; pick something out of AppKit's tag space.
    private static let codingMenuTag = 0x59_47_44_43 // "YGDC"

    func install() {
        // Listen for repeated lifecycle events so SwiftUI rebuilding the
        // main menu (which it does liberally — every scene mutation may
        // wipe our insertion) doesn't permanently lose us. install() is
        // idempotent thanks to the tag check.
        NotificationCenter.default.addObserver(
            self, selector: #selector(reinstallIfMissing),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(reinstallIfMissing),
            name: NSWindow.didBecomeKeyNotification, object: nil
        )
        reinstallIfMissing()
    }

    @objc private func reinstallIfMissing() {
        guard let mainMenu = NSApp.mainMenu else { return }
        // Already present? Done.
        if mainMenu.items.contains(where: { $0.tag == Self.codingMenuTag }) {
            return
        }
        let codingMenuItem = NSMenuItem(title: "Coding", action: nil, keyEquivalent: "")
        codingMenuItem.tag = Self.codingMenuTag
        let coding = NSMenu(title: "Coding")
        codingMenuItem.submenu = coding

        coding.addItem(menuItem(title: "Add Tracked Repo…",
                                action: #selector(addTrackedRepo),
                                keyEquivalent: "R", modifiers: [.command, .shift]))
        coding.addItem(menuItem(title: "Remove Tracked Repo…",
                                action: #selector(removeTrackedRepo),
                                keyEquivalent: ""))

        coding.addItem(.separator())
        coding.addItem(menuItem(title: "Force Sync Now",
                                action: #selector(forceSync),
                                keyEquivalent: "S", modifiers: [.command, .shift]))
        coding.addItem(menuItem(title: "Dump Tasks to Log",
                                action: #selector(dumpTasks),
                                keyEquivalent: ""))

        coding.addItem(.separator())
        coding.addItem(menuItem(title: "Add Agent…",
                                action: #selector(addAgent),
                                keyEquivalent: ""))
        coding.addItem(menuItem(title: "Remove Agent…",
                                action: #selector(removeAgent),
                                keyEquivalent: ""))
        coding.addItem(menuItem(title: "Set Default Agent…",
                                action: #selector(setDefaultAgent),
                                keyEquivalent: ""))

        coding.addItem(.separator())
        coding.addItem(menuItem(title: "+ New Session…",
                                action: #selector(newSession),
                                keyEquivalent: "N", modifiers: [.command, .shift]))

        // Insert after View if present; otherwise just before Window.
        let insertIndex: Int = {
            if let viewIndex = mainMenu.items.firstIndex(where: { $0.title == "View" }) {
                return viewIndex + 1
            }
            if let windowIndex = mainMenu.items.firstIndex(where: { $0.title == "Window" }) {
                return windowIndex
            }
            return mainMenu.items.count
        }()
        mainMenu.insertItem(codingMenuItem, at: insertIndex)
    }

    private func menuItem(
        title: String, action: Selector, keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    // MARK: - Selectors

    private var services: AppServices? { appDelegate?.services }

    @objc private func addTrackedRepo() {
        YggdrasilLog.ui.notice("Coding menu: Add Tracked Repo clicked")
        guard let database = services?.database else {
            DebugMenu.alert(title: "Yggdrasil not ready",
                            message: "Services not initialised yet. Try again in a second.")
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
            DebugMenu.alert(title: "Add tracked repo failed",
                            message: String(describing: error))
        }
    }

    @objc private func removeTrackedRepo() {
        YggdrasilLog.ui.notice("Coding menu: Remove Tracked Repo clicked")
        guard let database = services?.database else { return }
        do {
            let repos = try database.queue.read { db in try Repo.fetchAll(db) }
            guard !repos.isEmpty else {
                DebugMenu.alert(title: "No tracked repos",
                                message: "Use “Add Tracked Repo…” first.")
                return
            }
            guard let selected = DebugMenu.promptForRepoChoice(repos) else { return }
            try database.queue.write { db in try selected.delete(db) }
            YggdrasilLog.ui.info("Removed tracked repo \(selected.fullName)")
        } catch {
            DebugMenu.alert(title: "Remove tracked repo failed",
                            message: String(describing: error))
        }
    }

    @objc private func forceSync() {
        YggdrasilLog.ui.notice("Coding menu: Force Sync clicked")
        guard let services else { return }
        Task {
            do {
                try await services.syncService.fullSync()
                await MainActor.run { services.tabs.reload() }
            } catch {
                YggdrasilLog.ui.error("Force sync failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    @objc private func dumpTasks() {
        YggdrasilLog.ui.notice("Coding menu: Dump Tasks clicked")
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

    @objc private func addAgent() {
        YggdrasilLog.ui.notice("Coding menu: Add Agent clicked")
        guard let store = services?.agentStore else { return }
        guard let details = DebugMenu.promptForAgentDetails() else { return }
        do {
            _ = try store.add(name: details.name, command: details.command, args: details.args)
            YggdrasilLog.ui.info("Added coding agent \(details.name, privacy: .public)")
        } catch {
            DebugMenu.alert(title: "Add agent failed", message: String(describing: error))
        }
    }

    @objc private func removeAgent() {
        YggdrasilLog.ui.notice("Coding menu: Remove Agent clicked")
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

    @objc private func setDefaultAgent() {
        YggdrasilLog.ui.notice("Coding menu: Set Default Agent clicked")
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

    @objc private func newSession() {
        YggdrasilLog.ui.notice("Coding menu: New Session clicked")
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
