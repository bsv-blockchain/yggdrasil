import XCTest
@testable import Yggdrasil

/// Step order and rollback of moving a tab between this Mac and a host, with
/// every side effect stubbed out.
final class TabMigratorTests: XCTestCase {
    private let host = RemoteHost(id: 7, name: "dev", sshTarget: "dev", reposRoot: "/srv", createdAt: Date())
    private let repo = Repo(
        id: 1, owner: "acme", name: "widget", defaultBranch: "main", localMainPath: "/Users/me/widget", addedAt: Date()
    )

    /// Records each step; `failAt` makes that step throw.
    private final class Log: @unchecked Sendable {
        var steps: [String] = []
        var failAt: String?
        struct Boom: Error {}

        func step(_ name: String) throws {
            steps.append(name)
            if name == failAt { throw Boom() }
        }
    }

    private func environment(_ log: Log, clean: Bool = true, head: String? = "b") -> TabMigrator.Environment {
        TabMigrator.Environment(
            isClean: { _, _ in
                try log.step("check")
                return clean
            },
            headBranch: { _, _ in
                try log.step("head")
                return head
            },
            setMoving: { moving in log.steps.append(moving ? "moving" : "settled") },
            stopAgent: { _ in try log.step("stop") },
            moveBranch: { _ in try log.step("branch") },
            ensureWorktree: { request in
                try log.step("worktree")
                return request.destination == nil ? "/Users/me/widget/.worktrees/b" : "/srv/acme/widget/.worktrees/b"
            },
            copyTranscript: { _, _ in try log.step("transcript") },
            switchTab: { _, _ in try log.step("switch") },
            startAgent: { log.steps.append("start") }
        )
    }

    private func request(
        to destination: RemoteHost?, from source: RemoteHost? = nil, branch: String = "b"
    ) -> TabMigrator.Request {
        TabMigrator.Request(
            tabID: 3, repo: repo, branch: branch, sessionID: "sid",
            source: source,
            sourcePath: source == nil ? "/Users/me/widget/.worktrees/b" : "/srv/acme/widget/.worktrees/b",
            destination: destination
        )
    }

    private func refusal(_ log: Log, _ request: TabMigrator.Request, clean: Bool = true,
                         head: String? = "b") async -> Error? {
        do {
            _ = try await TabMigrator(environment: environment(log, clean: clean, head: head)).migrate(request)
            return nil
        } catch {
            return error
        }
    }

    func testLocalToHostRunsEveryStepInOrder() async throws {
        let log = Log()
        let path = try await TabMigrator(environment: environment(log)).migrate(request(to: host))
        XCTAssertEqual(path, "/srv/acme/widget/.worktrees/b")
        // The agent is stopped before the checks, so nothing it writes mid-turn
        // can slip past them; it's started before the tab settles, so the
        // main pane's auto-spawn never races it.
        XCTAssertEqual(log.steps, [
            "moving", "stop", "check", "head", "branch", "worktree", "transcript", "switch", "start", "settled"
        ])
    }

    func testHostToLocalRunsTheSameSteps() async throws {
        let log = Log()
        let path = try await TabMigrator(environment: environment(log)).migrate(request(to: nil, from: host))
        XCTAssertEqual(path, "/Users/me/widget/.worktrees/b")
        XCTAssertEqual(Array(log.steps.suffix(2)), ["start", "settled"])
    }

    func testDirtyWorktreeIsRefusedAndTheAgentRestarted() async {
        let log = Log()
        let error = await refusal(log, request(to: host), clean: false)
        XCTAssertEqual(error as? MigrationError, .dirtyWorktree("/Users/me/widget/.worktrees/b"))
        XCTAssertEqual(log.steps, ["moving", "stop", "check", "start", "settled"])
    }

    func testWorktreeOnAnotherBranchIsRefused() async {
        // The tab's recorded branch is what moves; if the worktree has since
        // switched, the real work would stay behind.
        let log = Log()
        let error = await refusal(log, request(to: host), head: "other")
        XCTAssertEqual(error as? MigrationError, .branchMismatch(expected: "b", actual: "other"))
        XCTAssertFalse(log.steps.contains("branch"))
        XCTAssertEqual(Array(log.steps.suffix(2)), ["start", "settled"])
    }

    func testDetachedHeadIsRefused() async {
        let error = await refusal(Log(), request(to: host), head: nil)
        XCTAssertEqual(error as? MigrationError, .branchMismatch(expected: "b", actual: nil))
    }

    func testAFailedStopAbortsTheMove() async {
        // An agent that may still be running must never get a twin on the
        // other side resuming the same conversation.
        let log = Log()
        log.failAt = "stop"
        let error = await refusal(log, request(to: nil, from: host))
        XCTAssertNotNil(error)
        XCTAssertEqual(log.steps, ["moving", "stop", "start", "settled"])
    }

    func testSameLocationIsRefused() async {
        let log = Log()
        let error = await refusal(log, request(to: host, from: host))
        XCTAssertEqual(error as? MigrationError, .sameLocation)
        XCTAssertEqual(log.steps, [])
    }

    func testHostToHostIsRefusedUpFront() async {
        let other = RemoteHost(id: 8, name: "build", sshTarget: "build", reposRoot: "/srv", createdAt: Date())
        let log = Log()
        let error = await refusal(log, request(to: other, from: host))
        XCTAssertEqual(error as? MigrationError, .hostToHost)
        XCTAssertEqual(log.steps, [])
    }

    func testDefaultBranchCannotMoveToAHost() async {
        // On a host the default branch belongs to the shared main checkout.
        let log = Log()
        let error = await refusal(log, request(to: host, branch: "main"))
        XCTAssertEqual(error as? MigrationError, .defaultBranchToHost("main"))
        XCTAssertEqual(log.steps, [])
    }

    func testMovingToThisMacNeedsALocalClone() async {
        var bare = repo
        bare.localMainPath = nil
        let request = TabMigrator.Request(
            tabID: 3, repo: bare, branch: "b", sessionID: nil,
            source: host, sourcePath: "/srv/acme/widget/.worktrees/b", destination: nil
        )
        let error = await refusal(Log(), request)
        XCTAssertEqual(error as? MigrationError, .noLocalClone("acme/widget"))
    }

    func testFailureBeforeTheSwitchRestartsTheSourceAgent() async {
        for failing in ["branch", "worktree", "transcript", "switch"] {
            let log = Log()
            log.failAt = failing
            let error = await refusal(log, request(to: host))
            XCTAssertNotNil(error, failing)
            XCTAssertEqual(Array(log.steps.suffix(2)), ["start", "settled"], "\(failing): \(log.steps)")
        }
    }

    func testNoSessionIDSkipsTheTranscript() async throws {
        let log = Log()
        let request = TabMigrator.Request(
            tabID: 3, repo: repo, branch: "b", sessionID: nil,
            source: nil, sourcePath: "/Users/me/widget/.worktrees/b", destination: host
        )
        _ = try await TabMigrator(environment: environment(log)).migrate(request)
        XCTAssertFalse(log.steps.contains("transcript"))
    }
}
