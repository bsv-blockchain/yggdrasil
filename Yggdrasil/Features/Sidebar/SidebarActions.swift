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
        guard let session = agentSession(tabID: tabID, services: services) else { return }
        services.sessions.clearExited(tabID: tabID)
        services.sessions.terminate(tabID: tabID)
        respawn(session, services: services)
    }

    /// The tab's agent as a session, wherever the tab row points now.
    @MainActor
    static func agentSession(tabID: Int64, services: AppServices) -> OpenSession? {
        guard let tab = services.tabs.tabs.first(where: { $0.id == tabID }),
              let agentID = tab.codingAgentID,
              let agent = try? services.agentStore.get(id: agentID)
        else { return nil }
        return OpenSession(
            id: tabID,
            displayName: "\(agent.name) \u{00b7} \(tab.branchName)",
            cwd: tab.worktreePath,
            command: agent.command,
            args: agent.args,
            env: agent.env,
            host: services.host(for: tab)
        )
    }

    @MainActor
    static func openShell(tabID: Int64, services: AppServices) {
        guard let session = services.sessions.sessions.first(where: { $0.id == tabID }) else { return }
        services.sessions.clearExited(tabID: tabID)
        services.sessions.terminate(tabID: tabID)
        // On a host, an empty command makes the helper start the user's own
        // login shell there.
        let shell = session.host == nil ? ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh" : ""
        respawn(OpenSession(
            id: tabID,
            displayName: "Shell",
            cwd: session.cwd,
            command: shell,
            args: [],
            host: session.host
        ), services: services)
    }

    /// The three-way remove-tab prompt, in the order the buttons are presented.
    ///
    /// Order is load-bearing: NSAlert binds Return to the *first* button, so the
    /// destructive option must never lead. It used to, and once the View-menu
    /// "Close Tab…" item started dispatching, a reflexive close-then-Return ran
    /// `git worktree remove --force` on the selected worktree with no undo.
    /// `hasDestructiveAction` only colours the button — it does not move it out
    /// of the default slot.
    enum RemoveTabChoice: CaseIterable {
        /// DB row + session; the worktree stays on disk.
        case tabOnly
        /// Also runs `git worktree remove --force`.
        case tabAndWorktree
        case cancel

        var title: String {
            switch self {
            case .tabOnly: "Remove Tab Only"
            case .tabAndWorktree: "Remove Tab + Worktree"
            case .cancel: "Cancel"
            }
        }

        var isDestructive: Bool {
            self == .tabAndWorktree
        }

        /// Read a `runModal()` response back through `allCases`, which is also
        /// what the buttons were added from — the two cannot drift apart.
        /// Anything unrecognised is treated as Cancel.
        static func from(response: NSApplication.ModalResponse) -> RemoveTabChoice {
            switch response {
            case .alertFirstButtonReturn: allCases[0]
            case .alertSecondButtonReturn: allCases[1]
            default: .cancel
            }
        }
    }

    /// Confirm-then-delete a tab. Tears down any running session and (optionally)
    /// removes the worktree on disk. See `RemoveTabChoice` for the prompt.
    @MainActor
    static func removeTab(id: Int64, services: AppServices) {
        guard let tab = services.tabs.tabs.first(where: { $0.id == id }) else { return }
        let host = services.host(for: tab)
        let alert = NSAlert()
        alert.messageText = "Remove this tab?"
        if let host {
            alert.informativeText = """
            Branch: \(tab.branchName)
            Worktree: \(tab.worktreePath) on \(host.name)

            The agent running on \(host.name) is stopped. Deleting the worktree runs \
            `git worktree remove --force` on the host, which discards any uncommitted work in it.
            """
        } else {
            alert.informativeText = """
            Branch: \(tab.branchName)
            Worktree: \(tab.worktreePath)

            Choose whether to keep the worktree on disk or delete it too. \
            Deleting the worktree runs `git worktree remove --force`, which \
            discards any uncommitted work inside it.
            """
        }
        alert.alertStyle = .warning
        for choice in RemoveTabChoice.allCases {
            alert.addButton(withTitle: choice.title).hasDestructiveAction = choice.isDestructive
        }
        let choice = RemoveTabChoice.from(response: alert.runModal())
        guard choice != .cancel else { return }
        Task { @MainActor in
            let problems = await (try? TabActions.close(
                id: id, deleteWorktree: choice == .tabAndWorktree, services: services
            )) ?? []
            guard !problems.isEmpty else { return }
            presentInfo(
                title: host.map { "Removed the tab, but not everything on \($0.name)" }
                    ?? "Removed the tab, but not its worktree",
                text: problems.joined(separator: "\n\n") + "\n\nWorktree: \(tab.worktreePath)"
            )
        }
    }

    /// Move sidebar tab selection by `delta` (wrapping at both ends) and mirror
    /// the new selection onto the live-session host. Driven by the View-menu
    /// Previous/Next Session commands (⌥↑ / ⌥↓), keeping the move-then-sync in
    /// one place.
    static func selectTab(by delta: Int, services: AppServices) {
        services.tabs.moveSelection(by: delta)
        if let id = services.tabs.selectedID {
            services.sessions.selectedID = id
        }
    }

    /// Mute this tab's amber until something actually changes. Records the
    /// current attention fingerprint; the mute lapses the moment a new commit,
    /// thread, review request or agent record changes it.
    @MainActor
    static func dismissAttention(tabID: Int64, services: AppServices) {
        do {
            try TabActions.mute(tabID: tabID, services: services)
        } catch ActionError.noStatusYet {
            presentInfo(title: "Not ready yet", text: "This tab has no status yet. Try again in a moment.")
        } catch {}
    }

    @MainActor
    static func restoreAttention(tabID: Int64, services: AppServices) {
        try? TabActions.unmute(tabID: tabID, services: services)
    }

    /// Re-run a worktree preparation that failed. Without this a failed tab is
    /// a dead end — the error is on the row, but the only way out would be to
    /// close it and start again.
    @MainActor
    static func retryPreparation(tab: YggdrasilTab, services: AppServices) {
        guard let tabID = tab.id else { return }
        do {
            try TabActions.retrySetup(tabID: tabID, services: services)
        } catch ActionError.notInTrackedRepo {
            presentInfo(title: "Can't prepare this tab", text: "This tab isn't inside a tracked repository.")
        } catch {
            YggdrasilLog.ui
                .error(
                    "Retry setup failed for tab \(tabID, privacy: .public): \(String(describing: error), privacy: .public)"
                )
        }
    }

    /// Clear a tab's PR link. On an issue tab carrying a linked PR, this drops
    /// just the PR and keeps the issue; on a PR-only tab it reverts to a plain
    /// terminal tab.
    @MainActor
    static func unlinkPR(id: Int64, services: AppServices) {
        do {
            try TabActions.unlinkPR(tabID: id, services: services)
        } catch {
            YggdrasilLog.ui.error(
                "unlinkPR failed for tab \(id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// "Link PR…" — turn an ad-hoc tab into a PR tab. Resolves the repo the
    /// tab's PRs live in (the repo's configured PR repo, else the repo
    /// itself), auto-detects the PR matching this tab's branch there, prompts
    /// for a number / URL / `owner/repo#N` (pre-filled), then imports + links.
    /// MainActor because it drives an NSAlert.
    @MainActor
    static func linkPR(tab: YggdrasilTab, services: AppServices) {
        guard let tabID = tab.id else { return }
        guard services.tabs.repoByTabID[tabID] != nil else {
            presentInfo(title: "Can't link a PR",
                        text: "This tab isn't inside a tracked repository.")
            return
        }
        Task { @MainActor in
            let prRepo: Repo
            do {
                prRepo = try TabActions.defaultPRRepo(tabID: tabID, services: services)
            } catch {
                presentInfo(title: "Can't link a PR", text: error.actionMessage)
                return
            }
            // Auto-detect: best-effort (no match just means no prefill).
            let suggested = await TabActions.suggestedPRNumber(tabID: tabID, services: services)
            guard let entered = promptForPRNumber(
                prefill: suggested.map(String.init) ?? "", defaultRepo: prRepo.fullName
            ), !entered.isEmpty else { return }
            let resolved: (target: LinkPRTarget, repo: Repo)
            do {
                resolved = try TabActions.resolvePR(entered, tabID: tabID, services: services)
            } catch ActionError.invalidArgument {
                presentInfo(title: "Enter a pull request",
                            text: "Couldn't read a PR from “\(entered)”. Use a PR number, a PR URL, or owner/repo#123.")
                return
            } catch let ActionError.repoNotTracked(slug) {
                presentInfo(title: "Couldn't link \(entered)",
                            text: "\(slug) isn't tracked. Add it in Preferences → Repos.")
                return
            } catch {
                presentInfo(title: "Can't link a PR", text: error.actionMessage)
                return
            }
            do {
                try await TabActions.linkPR(
                    tabID: tabID, repo: resolved.repo, number: resolved.target.number, services: services
                )
            } catch {
                presentInfo(title: "Couldn't link \(resolved.target.display)", text: error.actionMessage)
            }
        }
    }

    /// NSAlert with a text field. Returns the trimmed entry, or nil on cancel.
    @MainActor
    private static func promptForPRNumber(prefill: String, defaultRepo: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Link a Pull Request"
        alert.informativeText = "Enter a PR number in \(defaultRepo), a PR URL, or owner/repo#123."
        alert.addButton(withTitle: "Link")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = prefill
        field.placeholderString = "e.g. 828 or owner/repo#828"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Single-button informational NSAlert.
    @MainActor
    static func presentInfo(title: String, text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Remote tabs

extension SidebarActions {
    /// Mounts `session` in place of the one just terminated. Local: defer the
    /// re-add one runloop tick so SwiftUI can dismantle the old
    /// AgentTerminalSurface (and its dead PTY) before the replacement row
    /// mounts a fresh one. Remote: `terminate` only detached, so end the
    /// agent on the host first; otherwise `ygg attach` would just reattach
    /// to it. A failed kill (host unreachable) still respawns, and the new
    /// surface's reconnect loop takes over.
    @MainActor
    private static func respawn(_ session: OpenSession, services: AppServices) {
        guard let host = session.host else {
            DispatchQueue.main.async { services.sessions.add(session) }
            return
        }
        Task { @MainActor in
            do {
                try await services.remoteControl.kill(host: host, tabID: session.id)
            } catch {
                YggdrasilLog.ui.error(
                    "Remote kill failed for tab \(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
            services.sessions.add(session)
        }
    }
}
