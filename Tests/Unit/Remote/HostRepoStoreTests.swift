import GRDB
import XCTest
@testable import Yggdrasil

/// One checkout per repo per host: its path is pinned on first use and only
/// changes when the user moves it explicitly.
final class HostRepoStoreTests: XCTestCase {
    private var db: YggdrasilDatabase!
    private var store: HostRepoStore!
    private var host: RemoteHost!
    private var repo: Repo!

    override func setUpWithError() throws {
        db = try YggdrasilDatabase.inMemory()
        store = HostRepoStore(database: db)
        host = try HostStore(database: db).add(name: "dev", sshTarget: "dev", reposRoot: "/home/me/src")
        repo = try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "acme", name: "widget", defaultBranch: "main", localMainPath: nil, addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
    }

    override func tearDown() {
        db = nil
        store = nil
        super.tearDown()
    }

    func testV18AddsHostRepoTable() throws {
        let tables = try db.queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        XCTAssertTrue(tables.contains("host_repo"), "tables=\(tables)")
    }

    func testDefaultsToReposRootOwnerName() throws {
        XCTAssertEqual(try store.checkoutPath(host: host, repo: repo), "/home/me/src/acme/widget")
    }

    func testPinKeepsPathWhenHostRootChangesLater() throws {
        XCTAssertEqual(try store.pin(host: host, repo: repo), "/home/me/src/acme/widget")
        var moved = try XCTUnwrap(host)
        moved.reposRoot = "/data/repos"
        XCTAssertEqual(try store.checkoutPath(host: moved, repo: repo), "/home/me/src/acme/widget")
        XCTAssertEqual(try store.pin(host: moved, repo: repo), "/home/me/src/acme/widget")
    }

    func testCheckoutPathCanBeSetPerRepo() throws {
        try store.setCheckoutPath(host: host, repo: repo, path: "/work/widget")
        XCTAssertEqual(try store.checkoutPath(host: host, repo: repo), "/work/widget")
        XCTAssertEqual(try store.list(hostID: XCTUnwrap(host.id)).map(\.path), ["/work/widget"])
    }

    func testRejectsRelativeCheckoutPath() {
        XCTAssertThrowsError(try store.setCheckoutPath(host: host, repo: repo, path: "work/widget")) { error in
            XCTAssertEqual(error as? HostRepoStoreError, .notAbsolute("work/widget"))
        }
    }

    func testTwoReposCannotShareACheckout() throws {
        let other = try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "acme", name: "gadget", defaultBranch: "main", localMainPath: nil, addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
        try store.setCheckoutPath(host: host, repo: repo, path: "/work/shared")
        XCTAssertThrowsError(try store.setCheckoutPath(host: host, repo: other, path: "/work/shared"))
    }

    func testMovingCheckoutRefusedWhileTabsUseIt() throws {
        let pinned = try store.pin(host: host, repo: repo)
        try db.queue.write { db in
            var tab = YggdrasilTab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "b", worktreePath: pinned + "/.worktrees/b",
                lastMainView: .agent, createdAt: Date(), lastActiveAt: Date(), hostID: host.id
            )
            try tab.insert(db)
        }
        XCTAssertThrowsError(try store.setCheckoutPath(host: host, repo: repo, path: "/elsewhere")) { error in
            XCTAssertEqual(error as? HostRepoStoreError, .inUse(pinned))
        }
    }

    func testCheckoutPathIsNormalized() throws {
        try store.setCheckoutPath(host: host, repo: repo, path: "/work//widget/")
        XCTAssertEqual(try store.checkoutPath(host: host, repo: repo), "/work/widget")
    }

    func testTrailingSlashDoesNotDodgeTheInUseCheck() throws {
        try store.setCheckoutPath(host: host, repo: repo, path: "/work/widget/")
        try db.queue.write { db in
            var tab = YggdrasilTab(
                id: nil, taskID: nil, codingAgentID: nil, position: 0,
                branchName: "b", worktreePath: "/work/widget/.worktrees/b",
                lastMainView: .agent, createdAt: Date(), lastActiveAt: Date(), hostID: host.id
            )
            try tab.insert(db)
        }
        XCTAssertThrowsError(try store.setCheckoutPath(host: host, repo: repo, path: "/elsewhere")) { error in
            XCTAssertEqual(error as? HostRepoStoreError, .inUse("/work/widget"))
        }
    }

    func testPinOntoAPathAnotherRepoHoldsIsAReadableError() throws {
        let other = try db.queue.write { db in
            var repo = Repo(
                id: nil, owner: "acme", name: "gadget", defaultBranch: "main", localMainPath: nil, addedAt: Date()
            )
            try repo.insert(db)
            return repo
        }
        try store.setCheckoutPath(host: host, repo: other, path: "/home/me/src/acme/widget")
        XCTAssertThrowsError(try store.pin(host: host, repo: repo)) { error in
            XCTAssertEqual(
                error as? HostRepoStoreError, .pathTaken("/home/me/src/acme/widget", heldBy: "acme/gadget")
            )
        }
    }
}
