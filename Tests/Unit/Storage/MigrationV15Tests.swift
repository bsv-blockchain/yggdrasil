import GRDB
import XCTest
@testable import Yggdrasil

/// v15 — a tab exists before its worktree does.
///
/// Opening a review used to create the worktree first and insert the tab after,
/// so the click blocked on `git fetch` of a PR head. On a large repo that is
/// slow, and `WorktreeManager` holds the per-repo lock across it — so opening
/// several PRs at once left the later ones waiting on the lock until they timed
/// out. The tab is now inserted immediately and prepared in the background,
/// which needs somewhere to record how far that got.
final class MigrationV15Tests: XCTestCase {
    func testAddsPreparationColumnsToTab() throws {
        let db = try YggdrasilDatabase.inMemory()
        try db.queue.read { database in
            let columns = try database.columns(in: "tab").map(\.name)
            XCTAssertTrue(columns.contains("preparation_state"))
            XCTAssertTrue(columns.contains("preparation_error"))
        }
    }

    /// Existing tabs already have their worktree on disk, so they must come
    /// through as ready rather than queued behind a preparation that will
    /// never run.
    func testExistingRowsDefaultToReady() throws {
        let db = try YggdrasilDatabase.inMemory()
        let state: String? = try db.queue.write { database in
            try database.execute(
                sql: """
                INSERT INTO tab (position, branch_name, worktree_path, last_main_view, created_at, last_active_at)
                VALUES (0, 'feat/x', '/tmp/x', 'agent', '2026-01-01', '2026-01-01')
                """
            )
            return try String.fetchOne(database, sql: "SELECT preparation_state FROM tab")
        }
        XCTAssertEqual(state, "ready")
    }

    func testPreparationErrorIsNullable() throws {
        let db = try YggdrasilDatabase.inMemory()
        try db.queue.read { database in
            let column = try database.columns(in: "tab").first { $0.name == "preparation_error" }
            XCTAssertEqual(column?.isNotNull, false)
        }
    }
}
