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
}
