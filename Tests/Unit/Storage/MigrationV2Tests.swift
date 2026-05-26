import GRDB
@testable import Loom
import XCTest

final class MigrationV2Tests: XCTestCase {
    func testV2AddsCodingAgentTabAndSessionStateTables() throws {
        let db = try LoomDatabase.inMemory()
        let tables = try db.queue.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name"
            )
        }
        XCTAssertTrue(tables.contains("coding_agent"), "tables=\(tables)")
        XCTAssertTrue(tables.contains("tab"), "tables=\(tables)")
        XCTAssertTrue(tables.contains("session_state"), "tables=\(tables)")
    }

    func testV2SeedsClaudeAsDefaultAgentOnFreshDatabase() throws {
        let db = try LoomDatabase.inMemory()
        let agents = try db.queue.read { db in try CodingAgent.fetchAll(db) }
        XCTAssertEqual(agents.count, 1, "v2 must seed exactly one default agent")
        let claude = agents[0]
        XCTAssertEqual(claude.name, "Claude")
        XCTAssertEqual(claude.command, "claude")
        XCTAssertEqual(claude.args, ["--dangerously-skip-permissions"])
        XCTAssertTrue(claude.isDefault)
    }

    func testCodingAgentNameIsUnique() throws {
        let db = try LoomDatabase.inMemory()
        XCTAssertThrowsError(try db.queue.write { db in
            var dup = CodingAgent(
                id: nil, name: "Claude", command: "other",
                args: [], isDefault: false, position: 1,
                createdAt: Date(), updatedAt: Date()
            )
            try dup.insert(db)
        })
    }

    func testTabHasNullableTaskIDAndCodingAgentID() throws {
        let db = try LoomDatabase.inMemory()
        // Insert a tab with both FKs nil (ad-hoc tab not tied to a task or agent yet).
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.queue.write { db in
            var tab = Tab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "scratch", worktreePath: "/tmp/scratch",
                lastMainView: .agent, createdAt: now, lastActiveAt: now
            )
            try tab.insert(db)
        }
        let count = try db.queue.read { db in try Tab.fetchCount(db) }
        XCTAssertEqual(count, 1)
    }

    func testDeletingCodingAgentNullsTabReference() throws {
        let db = try LoomDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.queue.write { db in
            var agent = CodingAgent(
                id: nil, name: "Codex", command: "codex",
                args: [], isDefault: false, position: 1,
                createdAt: now, updatedAt: now
            )
            try agent.insert(db)
            let agentID = agent.id!

            var tab = Tab(
                id: nil, taskID: nil, codingAgentID: agentID, position: 0,
                branchName: "scratch", worktreePath: "/tmp/scratch",
                lastMainView: .agent, createdAt: now, lastActiveAt: now
            )
            try tab.insert(db)

            try agent.delete(db)
        }
        // Tab should still exist, with coding_agent_id set to NULL.
        let tab = try db.queue.read { db in try Tab.fetchOne(db) }
        XCTAssertNotNil(tab)
        XCTAssertNil(tab?.codingAgentID, "deleting an agent must null the tab reference, not cascade")
    }

    func testSessionStateCascadeOnTabDelete() throws {
        let db = try LoomDatabase.inMemory()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try db.queue.write { db in
            var tab = Tab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "scratch", worktreePath: "/tmp/scratch",
                lastMainView: .agent, createdAt: now, lastActiveAt: now
            )
            try tab.insert(db)
            let tabID = tab.id!

            try SessionState(
                tabID: tabID, cwd: "/tmp/scratch",
                agentCommand: "echo", agentArgs: ["hi"],
                lastKnownExitCode: nil, ptyStartedAt: now, ptyEndedAt: nil
            ).insert(db)

            try tab.delete(db)
        }
        let sessions = try db.queue.read { db in try SessionState.fetchCount(db) }
        XCTAssertEqual(sessions, 0, "deleting a tab should cascade to its session_state row")
    }
}
