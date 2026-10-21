import GRDB
import XCTest
@testable import Yggdrasil

final class HostStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var store: HostStore!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        store = HostStore(database: db)
    }

    override func tearDown() {
        db = nil
        store = nil
        super.tearDown()
    }

    func testV17AddsHostTableAndTabHostColumn() throws {
        let (tables, tabColumns) = try db.queue.read { db in
            try (
                String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'"),
                db.columns(in: "tab").map(\.name)
            )
        }
        XCTAssertTrue(tables.contains("host"), "tables=\(tables)")
        XCTAssertTrue(tabColumns.contains("host_id"), "columns=\(tabColumns)")
    }

    func testAddAndListRoundTrip() throws {
        let host = try store.add(name: "devbox", sshTarget: "me@devbox.lan", reposRoot: "/home/me/src")
        let read = try XCTUnwrap(try store.get(id: XCTUnwrap(host.id)))
        XCTAssertEqual(read.name, "devbox")
        XCTAssertEqual(read.sshTarget, "me@devbox.lan")
        XCTAssertEqual(read.reposRoot, "/home/me/src")
        XCTAssertEqual(try store.list(), [read])
    }

    func testNameIsUnique() throws {
        _ = try store.add(name: "devbox", sshTarget: "a", reposRoot: "/src")
        XCTAssertThrowsError(try store.add(name: "devbox", sshTarget: "b", reposRoot: "/src"))
    }

    func testRejectsTargetThatCouldBeReadAsAnOption() {
        for bad in ["-oProxyCommand=evil", "", "has space", "tab\there"] {
            XCTAssertThrowsError(try store.add(name: "x\(bad.count)", sshTarget: bad, reposRoot: "/src"),
                                 bad) { error in
                XCTAssertEqual(error as? HostStoreError, .invalidSSHTarget(bad))
            }
        }
    }

    func testRejectsRelativeReposRoot() {
        XCTAssertThrowsError(try store.add(name: "x", sshTarget: "devbox", reposRoot: "~/src")) { error in
            XCTAssertEqual(error as? HostStoreError, .reposRootNotAbsolute("~/src"))
        }
    }

    func testRemoveRefusedWhileTabsUseHost() throws {
        let host = try store.add(name: "devbox", sshTarget: "devbox", reposRoot: "/src")
        let hostID = try XCTUnwrap(host.id)
        try db.queue.write { db in
            var tab = YggdrasilTab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "b", worktreePath: "/src/o/r/.worktrees/b",
                lastMainView: .agent, createdAt: Date(), lastActiveAt: Date(), hostID: hostID
            )
            try tab.insert(db)
        }
        XCTAssertThrowsError(try store.remove(id: hostID)) { error in
            XCTAssertEqual(error as? HostStoreError, .hostInUse(hostID))
        }
        XCTAssertEqual(try store.list().count, 1)
    }

    func testRemoveUnusedHost() throws {
        let host = try store.add(name: "devbox", sshTarget: "devbox", reposRoot: "/src")
        try store.remove(id: XCTUnwrap(host.id))
        XCTAssertEqual(try store.list(), [])
    }

    func testRepoPathIsDerivedFromReposRoot() throws {
        let host = try store.add(name: "devbox", sshTarget: "devbox", reposRoot: "/home/me/src/")
        XCTAssertEqual(host.repoPath(owner: "bsv-blockchain", name: "teranode"), "/home/me/src/bsv-blockchain/teranode")
    }

    func testUpdateChangesFieldsWithSameValidation() throws {
        let host = try store.add(name: "devbox", sshTarget: "devbox", reposRoot: "/src")
        let id = try XCTUnwrap(host.id)
        try store.update(id: id, name: "dev", sshTarget: "me@dev", reposRoot: "/data/src")
        let read = try XCTUnwrap(try store.get(id: id))
        XCTAssertEqual([read.name, read.sshTarget, read.reposRoot], ["dev", "me@dev", "/data/src"])
        XCTAssertThrowsError(try store.update(id: id, name: "dev", sshTarget: "-x", reposRoot: "/src"))
        XCTAssertThrowsError(try store.update(id: id, name: "dev", sshTarget: "dev", reposRoot: "src"))
    }
}
