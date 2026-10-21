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

    private func environment(_ log: Log, clean: Bool = true) -> TabMigrator.Environment {
        TabMigrator.Environment(
            isClean: { _, _ in log.steps.append("check")
                return clean
            },
            setMoving: { moving in log.steps.append(moving ? "moving" : "settled") },
            stopAgent: { _ in log.steps.append("stop") },
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

    private func request(to destination: RemoteHost?, from source: RemoteHost? = nil) -> TabMigrator.Request {
        TabMigrator.Request(
            tabID: 3, repo: repo, branch: "b", sessionID: "sid",
            source: source,
            sourcePath: source == nil ? "/Users/me/widget/.worktrees/b" : "/srv/acme/widget/.worktrees/b",
            destination: destination
        )
    }

    func testLocalToHostRunsEveryStepInOrder() async throws {
        let log = Log()
        let path = try await TabMigrator(environment: environment(log)).migrate(request(to: host))
        XCTAssertEqual(path, "/srv/acme/widget/.worktrees/b")
        XCTAssertEqual(log.steps, [
            "check", "moving", "stop", "branch", "worktree", "transcript", "switch", "settled", "start"
        ])
    }

    func testHostToLocalRunsTheSameSteps() async throws {
        let log = Log()
        let path = try await TabMigrator(environment: environment(log)).migrate(request(to: nil, from: host))
        XCTAssertEqual(path, "/Users/me/widget/.worktrees/b")
        XCTAssertEqual(log.steps.last, "start")
    }

    func testDirtyWorktreeIsRefusedBeforeAnythingStops() async {
        let log = Log()
        do {
            _ = try await TabMigrator(environment: environment(log, clean: false)).migrate(request(to: host))
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? MigrationError, .dirtyWorktree("/Users/me/widget/.worktrees/b"))
        }
        XCTAssertEqual(log.steps, ["check"])
    }

    func testSameLocationIsRefused() async {
        let log = Log()
        do {
            _ = try await TabMigrator(environment: environment(log)).migrate(request(to: host, from: host))
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? MigrationError, .sameLocation)
        }
        XCTAssertEqual(log.steps, [])
    }

    func testMovingToThisMacNeedsALocalClone() async {
        var bare = repo
        bare.localMainPath = nil
        let request = TabMigrator.Request(
            tabID: 3, repo: bare, branch: "b", sessionID: nil,
            source: host, sourcePath: "/srv/acme/widget/.worktrees/b", destination: nil
        )
        do {
            _ = try await TabMigrator(environment: environment(Log())).migrate(request)
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? MigrationError, .noLocalClone("acme/widget"))
        }
    }

    func testFailureBeforeTheSwitchRestartsTheSourceAgent() async {
        for failing in ["branch", "worktree", "transcript", "switch"] {
            let log = Log()
            log.failAt = failing
            do {
                _ = try await TabMigrator(environment: environment(log)).migrate(request(to: host))
                XCTFail("expected \(failing) to fail")
            } catch {}
            XCTAssertEqual(Array(log.steps.suffix(2)), ["settled", "start"], "\(failing): \(log.steps)")
            XCTAssertFalse(log.steps.contains("switch") && failing != "switch", failing)
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

    func testHostToHostIsRefusedUpFront() async {
        let other = RemoteHost(id: 8, name: "build", sshTarget: "build", reposRoot: "/srv", createdAt: Date())
        let log = Log()
        do {
            _ = try await TabMigrator(environment: environment(log)).migrate(request(to: other, from: host))
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(error as? MigrationError, .hostToHost)
        }
        XCTAssertEqual(log.steps, [])
    }
}
