import GRDB
import XCTest
@testable import Yggdrasil

/// Repos, agents, hosts and settings: what the Coding menu, Settings panes,
/// window chrome and onboarding do, without their dialogs. Nothing here talks
/// to GitHub or a host, and UserDefaults writes go to a throwaway suite.
@MainActor
final class AppActionsTests: XCTestCase {
    private var services: AppServices!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var appearance: NSAppearance?

    override func setUp() async throws {
        appearance = NSApp.appearance
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        suiteName = "AppActionsTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("app-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        NSApp.appearance = appearance
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        services = nil
    }

    // MARK: - Repos

    func testAddRepoTakesAURLAndAnOptionalClone() async throws {
        let clone = try makeGitRepo("widget")
        let repo = try await RepoActions.add(
            "https://github.com/acme/widget.git", localPath: clone.path, defaultBranch: "trunk", services: services
        )
        XCTAssertEqual(repo.fullName, "acme/widget")
        XCTAssertEqual(repo.defaultBranch, "trunk")
        XCTAssertEqual(repo.localMainPath, clone.path)
        XCTAssertEqual(try allRepos().map(\.fullName), ["acme/widget"])
    }

    func testAddRepoRefusesSomethingThatIsntARepo() async {
        do {
            _ = try await RepoActions.add("not a repo", defaultBranch: "main", services: services)
            XCTFail("expected invalidArgument")
        } catch {
            XCTAssertEqual(error as? ActionError, .invalidArgument("repo"))
        }
    }

    func testRemoveRepo() async throws {
        let repo = try await RepoActions.add("acme/widget", defaultBranch: "main", services: services)
        try RepoActions.remove(id: XCTUnwrap(repo.id), services: services)
        XCTAssertTrue(try allRepos().isEmpty)
        XCTAssertThrowsError(try RepoActions.remove(id: 999, services: services)) { error in
            XCTAssertEqual(error as? ActionError, .unknownRepo(999))
        }
    }

    func testSetLocalPathNeedsAnExistingFolder() async throws {
        let repo = try await RepoActions.add("acme/widget", defaultBranch: "main", services: services)
        let id = try XCTUnwrap(repo.id)
        XCTAssertThrowsError(try RepoActions.setLocalPath(id: id, path: "/no/such/dir", services: services)) { error in
            XCTAssertEqual(error as? ActionError, .invalidArgument("path"))
        }
        try RepoActions.setLocalPath(id: id, path: root.path, services: services)
        XCTAssertEqual(try allRepos().first?.localMainPath, root.path)
    }

    func testCloningOntoAnExistingCloneJustUsesIt() async throws {
        let repo = try await RepoActions.add("acme/widget", defaultBranch: "main", services: services)
        let existing = try makeGitRepo("widget")
        let path = try await RepoActions.clone(id: XCTUnwrap(repo.id), to: existing.path, services: services)
        XCTAssertEqual(path, existing.path)
        XCTAssertEqual(try allRepos().first?.localMainPath, existing.path)
    }

    func testCloningOntoAFolderThatIsntARepoIsRefused() async throws {
        let repo = try await RepoActions.add("acme/widget", defaultBranch: "main", services: services)
        let occupied = root.appendingPathComponent("widget")
        try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
        do {
            _ = try await RepoActions.clone(id: XCTUnwrap(repo.id), to: occupied.path, services: services)
            XCTFail("expected folderExists")
        } catch {
            XCTAssertEqual(error as? ActionError, .folderExists(occupied.path))
        }
    }

    // MARK: - Agents

    func testAddAgentTrimsAndNeedsANameAndCommand() throws {
        let agent = try AgentActions.add(
            name: " Codex ", command: " codex ", args: ["--yolo"], env: ["A": "1"], services: services
        )
        XCTAssertEqual(agent.name, "Codex")
        XCTAssertEqual(agent.command, "codex")
        XCTAssertEqual(agent.env, ["A": "1"])
        XCTAssertThrowsError(try AgentActions.add(name: " ", command: "x", args: [], services: services)) { error in
            XCTAssertEqual(error as? ActionError, .invalidArgument("name"))
        }
    }

    func testTheDefaultAgentCantBeRemoved() throws {
        // The Coding menu used to allow it; the Settings pane never did.
        let defaultID = try XCTUnwrap(services.agentStore.getDefault()?.id)
        XCTAssertThrowsError(try AgentActions.remove(id: defaultID, services: services)) { error in
            XCTAssertEqual(error as? ActionError, .cannotRemoveDefaultAgent)
        }
        let other = try AgentActions.add(name: "Codex", command: "codex", args: [], services: services)
        try AgentActions.setDefault(id: XCTUnwrap(other.id), services: services)
        try AgentActions.remove(id: defaultID, services: services)
        XCTAssertEqual(try services.agentStore.list().map(\.name), ["Codex"])
    }

    func testUpdateAgentChangesOnlyWhatIsGiven() throws {
        let agent = try AgentActions.add(name: "Codex", command: "codex", args: ["a"], services: services)
        let id = try XCTUnwrap(agent.id)
        try AgentActions.update(id: id, args: ["b"], services: services)
        let updated = try XCTUnwrap(services.agentStore.get(id: id))
        XCTAssertEqual(updated.name, "Codex")
        XCTAssertEqual(updated.args, ["b"])
        XCTAssertThrowsError(try AgentActions.update(id: id, command: "", services: services)) { error in
            XCTAssertEqual(error as? ActionError, .invalidArgument("command"))
        }
    }

    // MARK: - Hosts

    func testRemovingTheDefaultHostClearsTheDefault() throws {
        let host = try HostActions.add(name: "dev", sshTarget: "me@dev", reposRoot: "/home/me/src", services: services)
        let id = try XCTUnwrap(host.id)
        try SettingsActions.setDefaultHost(id: id, services: services)
        XCTAssertEqual(services.defaultHostID, id)
        try HostActions.remove(id: id, services: services)
        XCTAssertNil(services.defaultHostID)
        XCTAssertTrue(try services.hostStore.list().isEmpty)
    }

    func testUpdateHostKeepsWhatIsntGiven() throws {
        let host = try HostActions.add(name: "dev", sshTarget: "me@dev", reposRoot: "/home/me/src", services: services)
        let id = try XCTUnwrap(host.id)
        try HostActions.update(id: id, name: "devbox", services: services)
        let updated = try XCTUnwrap(services.hostStore.get(id: id))
        XCTAssertEqual(updated.name, "devbox")
        XCTAssertEqual(updated.sshTarget, "me@dev")
    }

    func testDefaultHostMustExist() {
        XCTAssertThrowsError(try SettingsActions.setDefaultHost(id: 42, services: services)) { error in
            XCTAssertEqual(error as? ActionError, .unknownHost(42))
        }
    }

    // MARK: - Settings

    func testThemeAndGroupingPersist() {
        let grouping = expectation(forNotification: .sidebarGroupingChanged, object: nil)
        SettingsActions.setTheme(.dark, services: services)
        SettingsActions.setGroupByRepo(true, services: services)
        SettingsActions.setTerminalTheme(.light, defaults: defaults)
        wait(for: [grouping], timeout: 1)
        let settings = SettingsActions.read(services: services, defaults: defaults)
        XCTAssertEqual(settings.theme, .dark)
        XCTAssertTrue(settings.groupByRepo)
        XCTAssertEqual(settings.terminalTheme, .light)
    }

    func testIntervalsOutsideTheirRangeAreRefused() async {
        do {
            try await SettingsActions.setIntervals(syncSeconds: 1, statusProbeSeconds: nil, services: services)
            XCTFail("expected invalidArgument")
        } catch {
            XCTAssertEqual(error as? ActionError, .invalidArgument("syncSeconds"))
        }
    }

    // MARK: - Helpers

    private func allRepos() throws -> [Repo] {
        try services.database.queue.read { db in try Repo.fetchAll(db) }
    }

    private func makeGitRepo(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        return url
    }
}
