import AppKit
import Foundation
import GRDB

/// Tracked repositories: Settings → Repositories, the Coding menu, onboarding
/// and the New Session sheet's clone prompt.
@MainActor
enum RepoActions {
    /// Tracks `owner/name` (or a github.com URL to it). `defaultBranch` is
    /// looked up on GitHub when not given, falling back to `main`.
    @discardableResult
    static func add(
        _ slug: String, localPath: String? = nil, defaultBranch: String? = nil, services: AppServices
    ) async throws -> Repo {
        guard let (owner, name) = RepoPrefsPane.parseSlug(slug) else { throw ActionError.invalidArgument("repo") }
        if let localPath { try requireFolder(localPath) }
        var branch = defaultBranch
        if branch == nil {
            branch = try? await services.restClient.defaultBranch(owner: owner, name: name)
        }
        let repo = try await services.database.queue.write { [branch] db in
            var repo = Repo(
                id: nil, owner: owner, name: name, defaultBranch: branch ?? "main",
                localMainPath: localPath, addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
        services.tabs.reload()
        return repo
    }

    /// Stops tracking the repo. Its synced issues and PRs go with it.
    static func remove(id: Int64, services: AppServices) throws {
        let deleted = try services.database.queue.write { db in try Repo.deleteOne(db, key: id) }
        guard deleted else { throw ActionError.unknownRepo(id) }
        services.tabs.reload()
    }

    /// Points the repo at an existing clone on this Mac.
    static func setLocalPath(id: Int64, path: String, services: AppServices) throws {
        try requireFolder(path)
        try services.database.queue.write { db in
            try db.execute(sql: "UPDATE repo SET local_main_path = ? WHERE id = ?", arguments: [path, id])
            guard db.changesCount == 1 else { throw ActionError.unknownRepo(id) }
        }
        services.tabs.reload()
    }

    /// Where the repo's PRs live, for Link PR…: another tracked repo, or
    /// nil for the repo itself.
    static func setPRRepo(id: Int64, prRepoID: Int64?, services: AppServices) throws {
        if prRepoID == id { throw ActionError.invalidArgument("prRepo") }
        try services.database.queue.write { db in
            if let prRepoID, try Repo.fetchOne(db, key: prRepoID) == nil { throw ActionError.unknownRepo(prRepoID) }
            try db.execute(sql: "UPDATE repo SET pr_repo_id = ? WHERE id = ?", arguments: [prRepoID, id])
            guard db.changesCount == 1 else { throw ActionError.unknownRepo(id) }
        }
    }

    private static func requireFolder(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ActionError.invalidArgument("path")
        }
    }

    /// Clones the repo with `gh` to `target` (by default next to the other
    /// clones) and points the repo at it. A git repository already there is
    /// used as it is; any other folder there is refused. Returns the path.
    @discardableResult
    static func clone(id: Int64, to target: String? = nil, services: AppServices) async throws -> String {
        let repos = try await services.database.queue.read { db in try Repo.fetchAll(db) }
        guard let repo = repos.first(where: { $0.id == id }) else { throw ActionError.unknownRepo(id) }
        let path = target ?? (NewTabSheet.inferCloneParent(from: repos) as NSString).appendingPathComponent(repo.name)
        if !RepoPrefsPane.isValidGitRepo(path) {
            guard !FileManager.default.fileExists(atPath: path) else { throw ActionError.folderExists(path) }
            try await GitHubCloner().clone(owner: repo.owner, name: repo.name, to: path)
        }
        try setLocalPath(id: id, path: path, services: services)
        return path
    }
}

/// Coding agent profiles: Settings → Agents and the Coding menu.
@MainActor
enum AgentActions {
    @discardableResult
    static func add(
        name: String, command: String, args: [String], env: [String: String] = [:], services: AppServices
    ) throws -> CodingAgent {
        let name = name.trimmingCharacters(in: .whitespaces)
        let command = command.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw ActionError.invalidArgument("name") }
        guard !command.isEmpty else { throw ActionError.invalidArgument("command") }
        return try services.agentStore.add(name: name, command: command, args: args, env: env)
    }

    /// Changes only what's given; `env: [:]` clears the environment.
    static func update(
        id: Int64, name: String? = nil, command: String? = nil, args: [String]? = nil,
        env: [String: String]? = nil, services: AppServices
    ) throws {
        let name = name?.trimmingCharacters(in: .whitespaces)
        let command = command?.trimmingCharacters(in: .whitespaces)
        guard name?.isEmpty != true else { throw ActionError.invalidArgument("name") }
        guard command?.isEmpty != true else { throw ActionError.invalidArgument("command") }
        guard try services.agentStore.get(id: id) != nil else { throw ActionError.unknownAgent(id) }
        try services.agentStore.update(id: id, name: name, command: command, args: args, env: env)
    }

    /// The default agent stays: new tabs need one.
    static func remove(id: Int64, services: AppServices) throws {
        guard let agent = try services.agentStore.get(id: id) else { throw ActionError.unknownAgent(id) }
        guard !agent.isDefault else { throw ActionError.cannotRemoveDefaultAgent }
        try services.agentStore.remove(id: id)
    }

    static func setDefault(id: Int64, services: AppServices) throws {
        guard try services.agentStore.get(id: id) != nil else { throw ActionError.unknownAgent(id) }
        try services.agentStore.setDefault(id: id)
    }
}

/// Remote hosts: Settings → Hosts.
@MainActor
enum HostActions {
    @discardableResult
    static func add(name: String, sshTarget: String, reposRoot: String, services: AppServices) throws -> RemoteHost {
        try services.hostStore.add(
            name: name.trimmingCharacters(in: .whitespaces),
            sshTarget: sshTarget.trimmingCharacters(in: .whitespaces),
            reposRoot: reposRoot.trimmingCharacters(in: .whitespaces)
        )
    }

    /// Changes only what's given.
    static func update(
        id: Int64, name: String? = nil, sshTarget: String? = nil, reposRoot: String? = nil, services: AppServices
    ) throws {
        guard let host = try services.hostStore.get(id: id) else { throw ActionError.unknownHost(id) }
        let trim = { (value: String?) in value?.trimmingCharacters(in: .whitespaces) }
        try services.hostStore.update(
            id: id, name: trim(name) ?? host.name, sshTarget: trim(sshTarget) ?? host.sshTarget,
            reposRoot: trim(reposRoot) ?? host.reposRoot
        )
    }

    /// Refused while tabs still run on the host. Clears it as the default.
    static func remove(id: Int64, services: AppServices) throws {
        guard try services.hostStore.get(id: id) != nil else { throw ActionError.unknownHost(id) }
        try services.hostStore.remove(id: id)
        if services.defaultHostID == id { services.defaultHostID = nil }
    }

    /// Check Connection: reaches the host, looks for the tools tabs need, and
    /// installs or updates the `ygg` helper there.
    static func check(id: Int64, services: AppServices) async throws -> HostPreflightReport {
        guard let host = try services.hostStore.get(id: id) else { throw ActionError.unknownHost(id) }
        return try await services.remoteControl.preflight(host: host)
    }

    /// Where the repo's checkout lives on the host.
    static func setCheckoutPath(hostID: Int64, repoID: Int64, path: String, services: AppServices) throws {
        guard let host = try services.hostStore.get(id: hostID) else { throw ActionError.unknownHost(hostID) }
        guard let repo = try services.database.queue.read({ db in try Repo.fetchOne(db, key: repoID) }) else {
            throw ActionError.unknownRepo(repoID)
        }
        try services.hostRepoStore.setCheckoutPath(host: host, repo: repo, path: path)
    }
}

/// Settings → General, and the chrome's theme button.
@MainActor
enum SettingsActions {
    struct Snapshot: Equatable {
        var theme: AppearanceSettings.Mode
        var terminalTheme: AppearanceSettings.TerminalTheme
        var groupByRepo: Bool
        /// nil = this Mac.
        var defaultHostID: Int64?
        var syncSeconds: Int
        var statusProbeSeconds: Int
    }

    static func read(services: AppServices, defaults: UserDefaults = .standard) -> Snapshot {
        Snapshot(
            theme: AppearanceSettings.readMode(services: services),
            terminalTheme: AppearanceSettings.terminalTheme(defaults: defaults),
            groupByRepo: AppearanceSettings.readGroupByRepo(services: services),
            defaultHostID: services.defaultHostID,
            syncSeconds: services.intervals.syncSeconds,
            statusProbeSeconds: services.intervals.statusProbeSeconds
        )
    }

    static func setTheme(_ mode: AppearanceSettings.Mode, services: AppServices) {
        AppearanceSettings.apply(mode: mode, services: services)
    }

    static func setTerminalTheme(_ theme: AppearanceSettings.TerminalTheme, defaults: UserDefaults = .standard) {
        AppearanceSettings.setTerminalTheme(theme, defaults: defaults)
    }

    static func setGroupByRepo(_ value: Bool, services: AppServices) {
        AppearanceSettings.persistGroupByRepo(value, services: services)
    }

    /// Where new tabs run unless chosen otherwise; nil = this Mac.
    static func setDefaultHost(id: Int64?, services: AppServices) throws {
        if let id, try services.hostStore.get(id: id) == nil { throw ActionError.unknownHost(id) }
        services.defaultHostID = id
    }

    /// Changes the GitHub sync and git status intervals (seconds); nil keeps
    /// one. Rebuilds the scheduler, which syncs at once.
    static func setIntervals(syncSeconds: Int?, statusProbeSeconds: Int?, services: AppServices) async throws {
        let sync = syncSeconds ?? services.intervals.syncSeconds
        let status = statusProbeSeconds ?? services.intervals.statusProbeSeconds
        guard IntervalSettings.syncRange.contains(sync) else { throw ActionError.invalidArgument("syncSeconds") }
        guard IntervalSettings.statusProbeRange.contains(status) else {
            throw ActionError.invalidArgument("statusProbeSeconds")
        }
        await services.applyIntervals(IntervalSettings(syncSeconds: sync, statusProbeSeconds: status))
    }
}

/// The sync buttons: the chrome's, Coding ▸ Force Sync and the pickers'.
@MainActor
enum SyncActions {
    static func syncNow(services: AppServices) async throws {
        try await services.syncService.fullSync()
        services.tabs.reload()
    }
}

/// Help-menu items and quitting.
@MainActor
enum AppActions {
    /// What Help ▸ Diagnostics copies.
    static func diagnosticsReport() -> String {
        Diagnostics.composeReport()
    }

    static func revealCrashLogs() {
        Diagnostics.openCrashFolder()
    }

    static func quit() {
        NSApp.terminate(nil)
    }
}
