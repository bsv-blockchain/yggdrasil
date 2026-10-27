import XCTest
@testable import Yggdrasil

/// Covers the session-bookkeeping the terminal exit/resume flow relies on:
/// exit tracking (`markExited`/`clearExited`) and the replace-or-append
/// semantics of `add` that let Resume Session swap a tab's row in place
/// without leaving a duplicate.
@MainActor
final class SessionsModelTests: XCTestCase {
    private func session(_ id: Int64, name: String = "Claude", cwd: String = "/tmp") -> OpenSession {
        OpenSession(id: id, displayName: name, cwd: cwd, command: "claude", args: [])
    }

    func testMarkAndClearExited() {
        let model = SessionsModel()
        XCTAssertNil(model.exitedTabs[7])

        model.markExited(tabID: 7, exitCode: 0)
        XCTAssertEqual(model.exitedTabs[7], 0)

        model.clearExited(tabID: 7)
        XCTAssertNil(model.exitedTabs[7])
    }

    func testAddReplacesSameIdInPlace() {
        let model = SessionsModel()
        model.add(session(1, name: "Claude"))
        model.add(session(1, name: "Shell", cwd: "/work"))

        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].displayName, "Shell")
        XCTAssertEqual(model.sessions[0].cwd, "/work")
        XCTAssertEqual(model.selectedID, 1)
    }

    func testAddAppendsDistinctIds() {
        let model = SessionsModel()
        model.add(session(1))
        model.add(session(2))

        XCTAssertEqual(model.sessions.map(\.id), [1, 2])
        XCTAssertEqual(model.selectedID, 2)
    }

    func testReconnectCountsAttemptsUntilConnectionHolds() {
        let model = SessionsModel()
        XCTAssertEqual(model.beginReconnect(tabID: 3), 0)
        XCTAssertEqual(model.beginReconnect(tabID: 3), 1)
        XCTAssertTrue(model.reconnecting.contains(3))

        model.connectionHeld(tabID: 3)
        XCTAssertFalse(model.reconnecting.contains(3))
        XCTAssertEqual(model.beginReconnect(tabID: 3), 0)
    }

    func testRemoveClearsReconnectState() {
        let model = SessionsModel()
        model.add(session(4))
        _ = model.beginReconnect(tabID: 4)
        model.remove(id: 4)
        XCTAssertFalse(model.reconnecting.contains(4))
        XCTAssertEqual(model.beginReconnect(tabID: 4), 0)
    }

    func testReleaseLivePIDOnlyForTheCurrentProcess() {
        // A process that exits after its tab was terminated or respawned is
        // no longer the tab's pid; its exit must not be read as a dropped
        // connection, nor unregister the replacement.
        let model = SessionsModel()
        model.registerLivePID(100, for: 1)
        model.registerLivePID(200, for: 1)
        XCTAssertFalse(model.releaseLivePID(100, for: 1))
        XCTAssertTrue(model.releaseLivePID(200, for: 1))
        XCTAssertFalse(model.releaseLivePID(200, for: 1))
    }

    func testMovingTabsAreTrackedUntilTheMoveEnds() {
        let model = SessionsModel()
        XCTAssertTrue(model.beginMove(tabID: 5))
        XCTAssertFalse(model.beginMove(tabID: 5), "a second move of the same tab must be refused")
        XCTAssertTrue(model.movingTabs.contains(5))
        model.endMove(tabID: 5)
        XCTAssertFalse(model.movingTabs.contains(5))
    }

    func testATabIsOpenedOnceSelectedAndStaysOpened() {
        // Only opened tabs mount their pane (agent, GitHub web view, diff), so
        // a launch with many tabs starts one agent, not one per tab.
        let model = SessionsModel()
        XCTAssertFalse(model.isOpened(tabID: 4))
        model.markOpened(tabID: 4)
        XCTAssertTrue(model.isOpened(tabID: 4))
        model.markOpened(tabID: nil)
        XCTAssertEqual(model.openedTabs, [4])
    }

    func testRemovingATabForgetsItWasOpened() {
        let model = SessionsModel()
        model.markOpened(tabID: 4)
        model.forgetOpened(tabID: 4)
        XCTAssertFalse(model.isOpened(tabID: 4))
    }
}
