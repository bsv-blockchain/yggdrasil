import XCTest
@testable import Yggdrasil

/// The pinned Yggdrasil row: a Claude session with the Yggdrasil MCP loaded,
/// through the bundled yggctl and a key of its own.
@MainActor
final class ManagerSessionTests: XCTestCase {
    private var services: AppServices!
    private var dataDirectory: URL!

    override func setUp() async throws {
        services = try AppServices(database: YggdrasilDatabase.inMemory())
        services.requestSync = {}
        dataDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("manager-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dataDirectory)
        services = nil
    }

    func testRunsClaudeWithTheYggdrasilMCP() throws {
        let tab = try ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory)
        let session = try makeSession(tab)
        let folder = dataDirectory.appendingPathComponent("manager").path
        let defaultAgent = try XCTUnwrap(services.agentStore.getDefault())

        XCTAssertEqual(session.id, tab.id)
        XCTAssertEqual(session.cwd, folder)
        XCTAssertEqual(session.command, "claude")
        XCTAssertEqual(session.args, defaultAgent.args + [
            "--mcp-config", "\(folder)/mcp.json", "--strict-mcp-config", "--settings", "\(folder)/settings.json",
            "--append-system-prompt", ManagerSession.instructions
        ])
        XCTAssertEqual(session.env["YGGDRASIL_SOCKET"], "/data/control.sock")
        XCTAssertTrue(session.env["YGGDRASIL_API_KEY"]?.hasPrefix("ygg_") ?? false)
        XCTAssertEqual(try ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory).id, tab.id)
    }

    func testTheConfigNamesYggctlButNeverHoldsTheKey() throws {
        let session = try makeSession(ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory))
        let folder = dataDirectory.appendingPathComponent("manager")
        let config = try String(contentsOf: folder.appendingPathComponent("mcp.json"), encoding: .utf8)
        XCTAssertTrue(config.contains("/App.app/Contents/MacOS/yggctl"), config)
        XCTAssertTrue(config.contains(#""mcp""#), config)
        XCTAssertFalse(try config.contains(XCTUnwrap(session.env["YGGDRASIL_API_KEY"])))
        let mode = try FileManager.default.attributesOfItem(
            atPath: folder.appendingPathComponent("mcp.json").path
        )[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("CLAUDE.md").path))
    }

    func testTheUsersNotesInClaudeMdAreKept() throws {
        // The app's own instructions go in the system prompt; CLAUDE.md is
        // the user's, made once.
        let tab = try ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory)
        _ = try makeSession(tab)
        let notes = dataDirectory.appendingPathComponent("manager/CLAUDE.md")
        try "Prefer developers-env for new tabs.".write(to: notes, atomically: true, encoding: .utf8)
        _ = try makeSession(tab)
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "Prefer developers-env for new tabs.")
    }

    func testThePromptConfirmsEvenADirectRequest() {
        // "close X" from the user isn't the yes: the session restates what it
        // will do and waits.
        let prompt = ManagerSession.instructions
        XCTAssertTrue(prompt.contains("even when the user asked for it"), prompt)
        XCTAssertTrue(prompt.contains("explicit yes"), prompt)
        for tool in ["tab_close", "tab_terminate", "tab_restart", "tab_shell", "tab_move"] {
            XCTAssertTrue(prompt.contains(tool), tool)
        }
    }

    func testClaudeItselfAsksBeforeAnythingThatChangesThings() throws {
        // The prompt's rule alone didn't hold: the model took "close X" as
        // the yes. Claude Code's "ask" rules prompt even with
        // --dangerously-skip-permissions. Every full-scope tool asks unless
        // it's on the short free list, so a new action asks by default.
        let permissions = try settings()["permissions"] as? [String: Any]
        let ask = try XCTUnwrap(permissions?["ask"] as? [String])
        for tool in ["tab_send", "tab_close", "tab_terminate", "tab_restart", "tab_shell", "tab_move",
                     "repo_remove", "agent_update", "agent_setDefault", "settings_set", "app_quit"] {
            XCTAssertTrue(ask.contains("mcp__yggdrasil__\(tool)"), tool)
        }
        for tool in ["tabs_list", "tab_screen", "tab_open", "tab_start", "tab_select"] {
            XCTAssertFalse(ask.contains("mcp__yggdrasil__\(tool)"), tool)
        }
    }

    func testTheFreeListNamesRealTools() {
        // A rename would otherwise quietly turn a free tool into an asking
        // one, or worse, keep a stale name here.
        let names = Set(ActionCatalog.all.map(\.toolName))
        XCTAssertTrue(ManagerSession.freeTools.isSubset(of: names), "\(ManagerSession.freeTools.subtracting(names))")
    }

    func testTheShellCantReachTheAPIAroundTheRules() throws {
        let permissions = try settings()["permissions"] as? [String: Any]
        let deny = try XCTUnwrap(permissions?["deny"] as? [String])
        XCTAssertTrue(deny.contains("Bash(yggctl:*)"))
        XCTAssertTrue(deny.contains("Bash(/App.app/Contents/MacOS/yggctl:*)"))
        XCTAssertTrue(deny.contains("Bash(curl:*)"))
    }

    func testARevokedKeyIsReplaced() throws {
        // Settings → API has a Revoke button for it too.
        let tab = try ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory)
        let first = try makeSession(tab).env["YGGDRASIL_API_KEY"]
        let store = APIKeyStore(database: services.database)
        try store.revoke(id: XCTUnwrap(sessionKeys().first?.id))
        let second = try makeSession(tab).env["YGGDRASIL_API_KEY"]
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(try store.verify(secret: XCTUnwrap(second)))
    }

    func testAClaudeCommandInAnyCaseCounts() throws {
        let claude = try AgentActions.add(name: "Mine", command: "/opt/bin/Claude", args: ["--x"], services: services)
        try AgentActions.setDefault(id: XCTUnwrap(claude.id), services: services)
        let session = try makeSession(ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory))
        XCTAssertEqual(session.command, "/opt/bin/Claude")
        XCTAssertEqual(session.args.first, "--x")
    }

    func testOneKeyPerRunRevokedOnQuit() throws {
        let tab = try ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory)
        let first = try makeSession(tab).env["YGGDRASIL_API_KEY"]
        let again = try makeSession(tab).env["YGGDRASIL_API_KEY"]
        XCTAssertEqual(first, again, "a restart reuses it")
        XCTAssertEqual(try sessionKeys().count, 1)
        XCTAssertEqual(try sessionKeys().first?.scope, .full)

        ManagerSession.revokeKeys(services: services)
        XCTAssertEqual(try sessionKeys().count, 0, "also what launch does with a crash's leftovers")
        XCTAssertNotEqual(try makeSession(tab).env["YGGDRASIL_API_KEY"], first)
    }

    func testAnotherDefaultAgentStillRunsClaude() throws {
        let codex = try AgentActions.add(name: "Codex", command: "codex", args: ["--x"], env: [:], services: services)
        try AgentActions.setDefault(id: XCTUnwrap(codex.id), services: services)
        let session = try makeSession(ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory))
        XCTAssertEqual(session.command, "claude")
        XCTAssertEqual(Array(session.args.prefix(1)), ["--mcp-config"])
    }

    private func makeSession(_ tab: YggdrasilTab) throws -> OpenSession {
        try ManagerSession.session(
            tab: tab, services: services, dataDirectory: dataDirectory,
            yggctlPath: "/App.app/Contents/MacOS/yggctl", socketPath: "/data/control.sock"
        )
    }

    private func settings() throws -> [String: Any] {
        _ = try makeSession(ManagerSession.ensureTab(services: services, dataDirectory: dataDirectory))
        let data = try Data(contentsOf: dataDirectory.appendingPathComponent("manager/settings.json"))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func sessionKeys() throws -> [APIKey] {
        try APIKeyStore(database: services.database).list().filter { $0.name == ManagerSession.keyName }
    }
}
