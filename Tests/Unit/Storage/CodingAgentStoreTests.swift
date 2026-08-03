import XCTest
@testable import Yggdrasil

final class CodingAgentStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var store: CodingAgentStore!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        store = CodingAgentStore(database: db)
    }

    override func tearDown() {
        db = nil
        store = nil
        super.tearDown()
    }

    func testListReturnsSeededClaudeAfterFreshMigration() throws {
        let agents = try store.list()
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents[0].name, "Claude")
        XCTAssertTrue(agents[0].isDefault)
    }

    func testGetDefaultReturnsClaudeOnFreshDatabase() throws {
        let claude = try XCTUnwrap(try store.getDefault())
        XCTAssertEqual(claude.name, "Claude")
    }

    func testAddInsertsNewAgentWithIncreasingPosition() throws {
        let codex = try store.add(name: "Codex", command: "codex", args: ["--auto"])
        XCTAssertEqual(codex.name, "Codex")
        XCTAssertEqual(codex.command, "codex")
        XCTAssertEqual(codex.args, ["--auto"])
        XCTAssertFalse(codex.isDefault, "newly-added agent is not default")
        XCTAssertGreaterThan(codex.position, 0)

        let agents = try store.list()
        XCTAssertEqual(agents.count, 2)
        // Listed in position order.
        XCTAssertEqual(agents[0].name, "Claude")
        XCTAssertEqual(agents[1].name, "Codex")
    }

    func testAddWithDuplicateNameThrows() {
        XCTAssertThrowsError(try store.add(name: "Claude", command: "x", args: []))
    }

    func testRemoveById() throws {
        let codex = try store.add(name: "Codex", command: "codex", args: [])
        try store.remove(id: XCTUnwrap(codex.id))
        let names = try store.list().map(\.name)
        XCTAssertEqual(names, ["Claude"])
    }

    func testRemovingTheDefaultDoesNotPromoteAnother() throws {
        // Spec doesn't require auto-promotion; we just remove. The caller (debug
        // menu) is responsible for picking a new default if it wants one.
        _ = try store.add(name: "Codex", command: "codex", args: [])
        let claude = try XCTUnwrap(try store.getDefault())
        try store.remove(id: XCTUnwrap(claude.id))
        XCTAssertNil(try store.getDefault())
    }

    func testSetDefaultClearsPreviousDefault() throws {
        let codex = try store.add(name: "Codex", command: "codex", args: [])
        try store.setDefault(id: XCTUnwrap(codex.id))

        let defaultAgent = try XCTUnwrap(try store.getDefault())
        XCTAssertEqual(defaultAgent.name, "Codex")

        // The previous default (Claude) must no longer be default.
        let agents = try store.list()
        let claude = try XCTUnwrap(agents.first { $0.name == "Claude" })
        XCTAssertFalse(claude.isDefault)
    }

    func testSetDefaultOnNonexistentIdThrows() {
        XCTAssertThrowsError(try store.setDefault(id: 999))
    }

    func testUpdateChangesCommandAndArgsAndBumpsUpdatedAt() throws {
        let original = try XCTUnwrap(try store.getDefault())
        let before = original.updatedAt

        // Sleep a hair so updatedAt definitely advances.
        Thread.sleep(forTimeInterval: 0.01)

        try store.update(
            id: XCTUnwrap(original.id), name: "Claude", command: "claude-beta", args: ["--v2"], env: [:]
        )
        let after = try XCTUnwrap(try store.list().first { $0.name == "Claude" })

        XCTAssertEqual(after.command, "claude-beta")
        XCTAssertEqual(after.args, ["--v2"])
        XCTAssertGreaterThan(after.updatedAt, before)
    }

    // MARK: - Per-agent environment (issue #47)

    func testSeededClaudeHasNoEnvironmentOverrides() throws {
        let claude = try XCTUnwrap(try store.getDefault())
        XCTAssertEqual(claude.env, [:])
    }

    func testAddPersistsEnvironmentOverrides() throws {
        let work = try store.add(
            name: "Claude (work)", command: "claude", args: [],
            env: ["CLAUDE_PROFILE": "work", "ANTHROPIC_BASE_URL": "https://work.example"]
        )
        XCTAssertEqual(work.env, ["CLAUDE_PROFILE": "work", "ANTHROPIC_BASE_URL": "https://work.example"])

        let reloaded = try XCTUnwrap(try store.list().first { $0.name == "Claude (work)" })
        XCTAssertEqual(reloaded.env, work.env, "env must survive the round trip through env_json")
    }

    func testAddWithoutEnvDefaultsToEmpty() throws {
        let codex = try store.add(name: "Codex", command: "codex", args: [])
        XCTAssertEqual(codex.env, [:])
    }

    func testUpdateReplacesTheEnvironmentWholesale() throws {
        let agent = try store.add(name: "Codex", command: "codex", args: [], env: ["OLD": "1"])
        let id = try XCTUnwrap(agent.id)

        try store.update(id: id, name: "Codex", command: "codex", args: [], env: ["NEW": "2"])
        XCTAssertEqual(try XCTUnwrap(try store.get(id: id)).env, ["NEW": "2"])

        try store.update(id: id, name: "Codex", command: "codex", args: [], env: [:])
        XCTAssertEqual(try XCTUnwrap(try store.get(id: id)).env, [:], "clearing the editor clears the env")
    }
}
