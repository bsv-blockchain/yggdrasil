import GRDB
import XCTest
@testable import Yggdrasil

/// `tab.kind` (migration v21): the pinned Yggdrasil session is a row of its
/// own kind beside the user's tabs.
final class TabKindTests: XCTestCase {
    func testV21GivesExistingTabsTheTabKind() throws {
        // Rows from before v21 have no kind; the column default decides.
        let queue = try DatabaseQueue()
        try Migrations.register().migrate(queue, upTo: "v20")
        try queue.write { db in
            try db.execute(sql: """
            INSERT INTO tab (position, branch_name, worktree_path, last_main_view, created_at, last_active_at)
            VALUES (0, 'b', '/w', 'agent', '2026-01-01 00:00:00', '2026-01-01 00:00:00')
            """)
        }
        try Migrations.register().migrate(queue)
        let kind = try queue.read { db in try String.fetchOne(db, sql: "SELECT kind FROM tab") }
        XCTAssertEqual(kind, "tab")
    }

    func testAnUnknownKindStillLoads() throws {
        // A newer build's kind mustn't empty the sidebar of an older one.
        let db = try YggdrasilDatabase.inMemory()
        let store = TabStore(database: db)
        let tab = try store.insert(branchName: "b", worktreePath: "/w", agentID: nil, taskID: nil)
        try db.queue.write { db in
            try db.execute(sql: "UPDATE tab SET kind = 'from-the-future' WHERE id = ?", arguments: [tab.id])
        }
        XCTAssertEqual(try store.list().map(\.kind), [.tab])
    }
}
