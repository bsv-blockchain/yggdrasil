import AppKit
import Foundation

/// Right-click context-menu actions for sidebar rows. Pure side-effects — kept
/// outside the SwiftUI view so they're unit-testable in isolation if we want.
enum SidebarActions {
    /// Reveal the worktree directory in Finder. Falls back to "open the parent"
    /// if the path itself can't be reached (e.g. the worktree was deleted).
    static func openInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
        YggdrasilLog.ui.info("Reveal in Finder: \(path, privacy: .public)")
    }

    /// Open Terminal.app at the worktree path.
    static func openInTerminal(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url], withApplicationAt: terminalURL,
            configuration: config
        ) { _, error in
            if let error {
                YggdrasilLog.ui.error("Open Terminal.app failed: \(String(describing: error), privacy: .public)")
            } else {
                YggdrasilLog.ui.info("Opened Terminal.app at \(path, privacy: .public)")
            }
        }
    }

    @MainActor
    static func restartAgent(tabID: Int64, services: AppServices) {
        guard let tab = services.tabs.tabs.first(where: { $0.id == tabID }),
              let agentID = tab.codingAgentID,
              let agent = try? services.agentStore.get(id: agentID)
        else { return }
        services.sessions.clearExited(tabID: tabID)
        services.sessions.terminate(tabID: tabID)
        // Defer the re-add one runloop tick so SwiftUI can dismantle the old
        // AgentTerminalSurface (and its dead PTY) before the replacement row
        // mounts a fresh one.
        DispatchQueue.main.async {
            services.sessions.add(OpenSession(
                id: tabID,
                displayName: "\(agent.name) \u{00b7} \(tab.branchName)",
                cwd: tab.worktreePath,
                command: agent.command,
                args: agent.args
            ))
        }
    }

    @MainActor
    static func openShell(tabID: Int64, services: AppServices) {
        guard let session = services.sessions.sessions.first(where: { $0.id == tabID }) else { return }
        let cwd = session.cwd
        services.sessions.clearExited(tabID: tabID)
        services.sessions.terminate(tabID: tabID)
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // Defer the re-add one runloop tick so SwiftUI can dismantle the old
        // AgentTerminalSurface (and its dead PTY) before the replacement row
        // mounts a fresh one.
        DispatchQueue.main.async {
            services.sessions.add(OpenSession(
                id: tabID,
                displayName: "Shell",
                cwd: cwd,
                command: shell,
                args: []
            ))
        }
    }

    /// Confirm-then-delete a tab. Tears down any running session and (optionally)
    /// removes the worktree on disk. Three-way prompt:
    ///   - Remove Tab Only — DB row + session, worktree stays on disk.
    ///   - Remove Tab + Worktree — also runs `git worktree remove --force`.
    ///   - Cancel.
    static func removeTab(id: Int64, services: AppServices) {
        guard let tab = services.tabs.tabs.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Remove this tab?"
        alert.informativeText = """
        Branch: \(tab.branchName)
        Worktree: \(tab.worktreePath)

        Choose whether to keep the worktree on disk or delete it too. \
        Deleting the worktree runs `git worktree remove --force`, which \
        discards any uncommitted work inside it.
        """
        alert.alertStyle = .warning
        let removeAndDeleteButton = alert.addButton(withTitle: "Remove Tab + Worktree")
        alert.addButton(withTitle: "Remove Tab Only")
        alert.addButton(withTitle: "Cancel")
        // First button is the default; make the destructive option visually marked.
        removeAndDeleteButton.hasDestructiveAction = true

        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn:
            performRemoval(id: id, tab: tab, deleteWorktree: true, services: services)
        case .alertSecondButtonReturn:
            performRemoval(id: id, tab: tab, deleteWorktree: false, services: services)
        default:
            return
        }
    }

    private static func performRemoval(
        id: Int64, tab: YggdrasilTab, deleteWorktree: Bool, services: AppServices
    ) {
        // Tear down the running agent first so its files aren't held open
        // by the time `git worktree remove` runs.
        services.sessions.remove(id: id)

        if deleteWorktree {
            // Resolve the owning repo from the worktree's grandparent dir
            // (WorktreeManager places worktrees at <repoParent>/.worktrees/<slug>).
            let repo = services.tabs.repoByTabID[id]
            if let repo {
                let worktreeURL = URL(fileURLWithPath: tab.worktreePath, isDirectory: true)
                Task {
                    do {
                        try await services.worktreeManager.remove(
                            repo: repo, path: worktreeURL, force: true
                        )
                        YggdrasilLog.ui.info(
                            "Removed worktree \(tab.worktreePath, privacy: .public) for tab \(id, privacy: .public)"
                        )
                    } catch {
                        YggdrasilLog.ui.error(
                            "git worktree remove failed for \(tab.worktreePath, privacy: .public): \(String(describing: error), privacy: .public)"
                        )
                    }
                }
            } else {
                YggdrasilLog.ui.warning(
                    "Could not resolve repo for tab \(id, privacy: .public); skipping worktree removal"
                )
            }
        }

        do {
            try services.tabStore.delete(id: id)
        } catch {
            YggdrasilLog.ui.error(
                "Failed to delete tab \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        services.tabs.reload()
        // GitHub-side state (pr_review_request, CI status) may have changed
        // while this tab was open (user approved, status flipped). Sync
        // now so the review pill + per-tab status catch up immediately
        // instead of waiting for the next scheduled tick.
        Task { @MainActor in services.triggerSyncNow() }
    }
}
