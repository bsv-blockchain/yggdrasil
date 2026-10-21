import XCTest
@testable import Yggdrasil

final class SessionStateStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    private func makeTab() throws -> Int64 {
        try db.queue.write { db in
            var tab = YggdrasilTab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "scratch", worktreePath: "/tmp/scratch",
                lastMainView: .agent, createdAt: Date(), lastActiveAt: Date()
            )
            try tab.insert(db)
            return tab.id!
        }
    }

    func testStartCreatesRowWithExpectedFields() throws {
        let store = SessionStateStore(database: db)
        let tabID = try makeTab()
        let row = try store.start(
            tabID: tabID,
            cwd: "/tmp/scratch",
            command: "claude",
            args: ["--dangerously-skip-permissions"]
        )
        XCTAssertEqual(row.tabID, tabID)
        XCTAssertEqual(row.cwd, "/tmp/scratch")
        XCTAssertEqual(row.agentCommand, "claude")
        XCTAssertEqual(row.agentArgs, ["--dangerously-skip-permissions"])
        XCTAssertNil(row.lastKnownExitCode)
        XCTAssertNil(row.ptyEndedAt)
    }

    func testStartIsIdempotentReplacesPriorRow() throws {
        let store = SessionStateStore(database: db)
        let tabID = try makeTab()
        _ = try store.start(tabID: tabID, cwd: "/tmp/a", command: "claude", args: [])
        let second = try store.start(tabID: tabID, cwd: "/tmp/b", command: "codex", args: ["--auto"])
        XCTAssertEqual(second.cwd, "/tmp/b")
        XCTAssertEqual(second.agentCommand, "codex")
        XCTAssertEqual(second.agentArgs, ["--auto"])

        let count = try db.queue.read { db in try SessionState.fetchCount(db) }
        XCTAssertEqual(count, 1, "start() must upsert, not insert a duplicate")
    }

    func testEndRecordsExitCodeAndPtyEndedAt() throws {
        let store = SessionStateStore(database: db)
        let tabID = try makeTab()
        let started = try store.start(tabID: tabID, cwd: "/tmp/x", command: "echo", args: ["hi"])
        Thread.sleep(forTimeInterval: 0.01)
        try store.end(tabID: tabID, exitCode: 0)

        let after = try XCTUnwrap(try store.get(tabID: tabID))
        XCTAssertEqual(after.lastKnownExitCode, 0)
        XCTAssertNotNil(after.ptyEndedAt)
        XCTAssertGreaterThan(try XCTUnwrap(after.ptyEndedAt), started.ptyStartedAt)
    }

    func testEndOnMissingRowIsNoOp() throws {
        let store = SessionStateStore(database: db)
        try store.end(tabID: 9999, exitCode: 42) // no row exists; must not throw
        XCTAssertNil(try store.get(tabID: 9999))
    }

    func testStartPersistsClaudeSessionID() throws {
        let store = SessionStateStore(database: db)
        let tabID = try makeTab()
        _ = try store.start(tabID: tabID, cwd: "/tmp/x", command: "claude", args: [], claudeSessionID: "sid-1")
        XCTAssertEqual(try store.get(tabID: tabID)?.claudeSessionID, "sid-1")
    }

    func testStartWithoutSessionIDKeepsStoredOne() throws {
        // "Open Shell" respawns the tab with $SHELL; that must not forget the
        // Claude conversation the tab is pinned to.
        let store = SessionStateStore(database: db)
        let tabID = try makeTab()
        _ = try store.start(tabID: tabID, cwd: "/tmp/x", command: "claude", args: [], claudeSessionID: "sid-1")
        let shell = try store.start(tabID: tabID, cwd: "/tmp/x", command: "/bin/zsh", args: [])
        XCTAssertEqual(shell.claudeSessionID, "sid-1")
        XCTAssertEqual(try store.get(tabID: tabID)?.claudeSessionID, "sid-1")
    }

    func testStartWithNewSessionIDReplacesStoredOne() throws {
        let store = SessionStateStore(database: db)
        let tabID = try makeTab()
        _ = try store.start(tabID: tabID, cwd: "/tmp/x", command: "claude", args: [], claudeSessionID: "sid-1")
        _ = try store.start(tabID: tabID, cwd: "/tmp/x", command: "claude", args: [], claudeSessionID: "sid-2")
        XCTAssertEqual(try store.get(tabID: tabID)?.claudeSessionID, "sid-2")
    }

    func testGetReturnsNilForUnknownTab() throws {
        let store = SessionStateStore(database: db)
        XCTAssertNil(try store.get(tabID: 1234))
    }
}
