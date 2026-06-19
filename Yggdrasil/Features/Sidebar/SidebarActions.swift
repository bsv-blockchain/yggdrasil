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

        // Optimistic dismissal: if this tab's task was in pr_review_request
        // (a "PR to review" the user just finished with), drop the
        // membership locally BEFORE we reload. Without this the count
        // briefly bounces up to 2 — the tab no longer hides the row, but
        // the next scheduled sync hasn't yet learned the user submitted
        // a review — and only settles back to 1 after the sync round-
        // trip. The next sync will restore the row in the rare case
        // the user closed without actually approving.
        if let taskID = services.tabs.tasksByTabID[id]?.id {
            try? services.database.queue.write { db in
                try db.execute(
                    sql: "DELETE FROM pr_review_request WHERE task_id = ?",
                    arguments: [taskID]
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

    /// Clear a tab's PR link. On an issue tab carrying a linked PR, this drops
    /// just the PR and keeps the issue; on a PR-only tab it reverts to a plain
    /// terminal tab.
    @MainActor
    static func unlinkPR(id: Int64, services: AppServices) {
        do {
            let tab = services.tabs.tabs.first { $0.id == id }
            if tab?.prTaskID != nil {
                try services.tabStore.setPRTaskID(id: id, prTaskID: nil)
            } else {
                try services.tabStore.setTaskID(id: id, taskID: nil)
            }
        } catch {
            YggdrasilLog.ui.error(
                "unlinkPR failed for tab \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        services.tabs.reload()
    }

    /// "Link PR…" — turn an ad-hoc tab into a PR tab. Resolves the owning
    /// repo, auto-detects the PR matching this tab's branch, prompts for a
    /// number (pre-filled), then imports + links. MainActor because it
    /// drives an NSAlert.
    @MainActor
    static func linkPR(tab: YggdrasilTab, services: AppServices) {
        guard let tabID = tab.id else { return }
        guard let repo = services.tabs.repoByTabID[tabID] else {
            presentInfo(title: "Can't link a PR",
                        text: "This tab isn't inside a tracked repository.")
            return
        }
        let owner = repo.owner
        let name = repo.name

        Task { @MainActor in
            // Auto-detect: best-effort, ignore errors (just means no prefill).
            let suggested = try? await services.syncService.linkablePRNumber(
                forBranch: tab.branchName, owner: owner, name: name
            )
            let prefill = suggested.map(String.init) ?? ""

            guard let entered = promptForPRNumber(prefill: prefill), !entered.isEmpty else { return }
            let interpreted = NewTabSheet.interpretBranchInput(entered).branch
            guard let number = NewTabSheet.parsePRNumber(interpreted) else {
                presentInfo(title: "Enter a PR number",
                            text: "Couldn't read a PR number from “\(entered)”.")
                return
            }

            do {
                let taskID = try await services.syncService.importPR(
                    owner: owner, name: name, number: number
                )
                if services.tabs.tasksByTabID[tabID]?.type == .issue {
                    // Issue tab: keep the issue as primary, attach the PR
                    // alongside it so the row shows both.
                    try services.tabStore.setPRTaskID(id: tabID, prTaskID: taskID)
                } else {
                    // Ad-hoc / PR-only tab: the PR becomes the primary task.
                    try services.tabStore.setTaskID(id: tabID, taskID: taskID)
                }
                services.tabs.reload()
                services.triggerSyncNow()
            } catch {
                presentInfo(title: "Couldn't link PR #\(number)",
                            text: String(describing: error))
            }
        }
    }

    /// NSAlert with a text field. Returns the trimmed entry, or nil on cancel.
    @MainActor
    private static func promptForPRNumber(prefill: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Link a Pull Request"
        alert.informativeText = "Enter the PR number to link to this tab."
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = prefill
        field.placeholderString = "e.g. 828"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single-button informational NSAlert.
    @MainActor
    private static func presentInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
