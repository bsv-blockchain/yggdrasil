import AppKit
import Darwin
import Foundation

extension TabMigrator {
    /// The real side effects behind each step, for `tabID`. `transcripts`
    /// is injectable so tests don't touch this Mac's ~/.claude.
    @MainActor
    static func live(
        tabID: Int64, services: AppServices, transcripts: TranscriptTransfer = TranscriptTransfer()
    ) -> Environment {
        Environment(
            isClean: { host, path in
                let status = try await git(on: host).run(
                    args: ["status", "--porcelain"], cwd: URL(fileURLWithPath: path, isDirectory: true)
                )
                return status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            },
            setMoving: { moving in
                await MainActor.run {
                    try? services.tabStore.setPreparation(id: tabID, state: moving ? .preparing : .ready)
                    services.tabs.reload()
                }
            },
            stopAgent: { host in
                await stopAgent(tabID: tabID, host: host, services: services)
            },
            moveBranch: { request in
                try await moveBranch(request, hostRepos: services.hostRepoStore)
            },
            ensureWorktree: { request in
                let manager = if let host = request.destination {
                    try await AppServices.remoteWorktreeManager(
                        on: host, repo: request.repo, hostRepos: services.hostRepoStore
                    )
                } else {
                    await MainActor.run { services.worktreeManager }
                }
                return try await manager.ensure(repo: request.repo, branch: request.branch).path
            },
            copyTranscript: { request, destinationPath in
                guard let sessionID = request.sessionID else { return }
                if let host = request.destination {
                    try await transcripts.upload(sessionID: sessionID, to: host, cwd: destinationPath)
                } else if let host = request.source {
                    try await transcripts.download(sessionID: sessionID, from: host, cwd: destinationPath)
                }
            },
            switchTab: { request, destinationPath in
                try await MainActor.run {
                    try services.tabStore.move(
                        id: tabID,
                        hostID: request.destination?.id,
                        worktreePath: destinationPath
                    )
                }
            },
            startAgent: {
                await MainActor.run {
                    services.tabs.reload()
                    SidebarActions.restartAgent(tabID: tabID, services: services)
                }
            }
        )
    }

    private static func git(on host: RemoteHost?) -> GitRunner {
        guard let host else { return GitRunner() }
        return GitRunner(runner: SSHSubprocessRunner(host: host), gitExecutable: "git")
    }

    /// Ends the agent and waits for it to go, so its transcript is complete
    /// before it's copied.
    @MainActor
    private static func stopAgent(tabID: Int64, host: RemoteHost?, services: AppServices) async {
        if let host {
            try? await services.remoteControl.kill(host: host, tabID: tabID)
            services.sessions.terminate(tabID: tabID)
            return
        }
        let pid = services.sessions.livePID(for: tabID)
        services.sessions.terminate(tabID: tabID)
        guard let pid, pid > 0 else { return }
        for _ in 0 ..< 50 where kill(pid, 0) == 0 {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Branch over ssh: pushed to the host's checkout, or fetched from it into
    /// the local clone, then adopted fast-forward only on the receiving side.
    private static func moveBranch(_ request: Request, hostRepos: HostRepoStore) async throws {
        switch (request.source, request.destination) {
        case let (nil, host?):
            let checkout = try hostRepos.pin(host: host, repo: request.repo)
            try await RemoteWorktreeSite(host: host, checkoutPath: { _ in checkout }).ensureCloned(request.repo)
            try await BranchTransfer.push(
                branch: request.branch, from: URL(fileURLWithPath: request.sourcePath, isDirectory: true),
                to: BranchTransfer.url(host: host, path: checkout), git: GitRunner()
            )
            try await BranchTransfer.adopt(
                branch: request.branch, checkout: URL(fileURLWithPath: checkout, isDirectory: true), git: git(on: host)
            )
        case let (host?, nil):
            guard let main = request.repo.localMainPath else {
                throw MigrationError.noLocalClone(request.repo.fullName)
            }
            let checkout = try hostRepos.checkoutPath(host: host, repo: request.repo)
            let local = URL(fileURLWithPath: main, isDirectory: true)
            try await BranchTransfer.fetch(
                branch: request.branch, from: BranchTransfer.url(host: host, path: checkout), into: local,
                git: GitRunner()
            )
            try await BranchTransfer.adopt(branch: request.branch, checkout: local, git: GitRunner())
        default:
            throw MigrationError.hostToHost
        }
    }
}

extension SidebarActions {
    /// "Move to ▸ …": confirm, then move the tab's branch, worktree and
    /// conversation to `destination` (nil = this Mac).
    @MainActor
    static func moveTab(_ tab: YggdrasilTab, to destination: RemoteHost?, services: AppServices) {
        guard let tabID = tab.id, let repo = services.tabs.repoByTabID[tabID] else {
            presentInfo(title: "Can't move this tab", text: "This tab isn't inside a tracked repository.")
            return
        }
        let source = services.host(for: tab)
        let alert = NSAlert()
        alert.messageText = "Move “\(tab.branchName)” to \(destination?.name ?? "this Mac")?"
        alert.informativeText = """
        The agent stops here and resumes there with its conversation. Only committed work moves: \
        commit or stash first. The worktree here stays until you remove it.
        """
        alert.addButton(withTitle: "Move")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let request = TabMigrator.Request(
            tabID: tabID, repo: repo, branch: tab.branchName,
            sessionID: try? services.sessionStore.get(tabID: tabID)?.claudeSessionID,
            source: source, sourcePath: tab.worktreePath, destination: destination
        )
        Task { @MainActor in
            do {
                try await TabMigrator(environment: TabMigrator.live(tabID: tabID, services: services)).migrate(request)
            } catch {
                presentInfo(title: "Couldn't move “\(tab.branchName)”", text: describe(error))
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let MigrationError.dirtyWorktree(path):
            "\(path) has uncommitted changes. Commit or stash them first; only committed work moves."
        case let MigrationError.branchDiverged(branch):
            "\(branch) has commits on both sides. Bring them together by hand first; nothing was overwritten."
        case let MigrationError.noLocalClone(repo):
            "\(repo) isn't cloned on this Mac. Set its location in Settings → Repositories."
        case let MigrationError.transcriptCopyFailed(message):
            "Copying the conversation failed: \(message)"
        case MigrationError.hostToHost:
            "Move the tab to this Mac first, then to the other host."
        case let WorktreeError.gitFailed(stderr, _):
            stderr
        default:
            String(describing: error)
        }
    }
}
