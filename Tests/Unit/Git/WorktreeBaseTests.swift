import XCTest
@testable import Yggdrasil

/// What a new tab's branch starts from.
final class WorktreeBaseTests: XCTestCase {
    private var fixture: FixtureGitRepo!

    override func setUp() async throws {
        try await super.setUp()
        fixture = try await FixtureGitRepo.create(named: "base")
    }

    override func tearDown() async throws {
        fixture?.cleanup()
        fixture = nil
        try await super.tearDown()
    }

    /// The New Session sheet and the API pass the repo's default branch as
    /// the base. In a checkout that has it only as `origin/main`, git's
    /// `worktree add -b <branch> <path> main` creates and checks out a local
    /// `main` instead of `<branch>` (git 2.54), so the tab's agent worked on
    /// main itself.
    func testABaseThatExistsOnlyOnOriginStillGivesTheTabItsOwnBranch() async throws {
        let runner = ProcessRunner()
        let clone = fixture.parent.appendingPathComponent("clone")
        _ = try await runner.runOrThrow(
            args: ["clone", "-q", fixture.repoURL.path, clone.path], cwd: fixture.parent
        )
        _ = try await runner.runOrThrow(args: ["checkout", "-q", "-b", "elsewhere"], cwd: clone)
        _ = try await runner.runOrThrow(args: ["branch", "-D", "main"], cwd: clone)
        var repo = fixture.repo
        repo.localMainPath = clone.path

        let path = try await WorktreeManager().ensure(repo: repo, branch: "claude-feat", baseRef: "main")

        let current = try await runner.runOrThrow(args: ["branch", "--show-current"], cwd: path)
        XCTAssertEqual(current.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "claude-feat")
        let mainLocally = try await runner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", clone.path, "rev-parse", "--verify", "--quiet", "refs/heads/main"]
        )
        XCTAssertNotEqual(mainLocally.exitCode, 0, "no local main was made")
    }

    func testWithoutABaseTheDefaultBranchOnlyOnOriginWorksToo() async throws {
        let clone = try await cloneWithoutLocalMain()
        var repo = fixture.repo
        repo.localMainPath = clone.path
        let path = try await WorktreeManager().ensure(repo: repo, branch: "claude-nil", baseRef: nil)
        let current = try await currentBranch(path)
        XCTAssertEqual(current, "claude-nil")
    }

    func testARemoteNotNamedOriginWorksToo() async throws {
        let clone = try await cloneWithoutLocalMain(remote: "upstream")
        var repo = fixture.repo
        repo.localMainPath = clone.path
        let path = try await WorktreeManager().ensure(repo: repo, branch: "claude-up", baseRef: "main")
        let current = try await currentBranch(path)
        XCTAssertEqual(current, "claude-up")
    }

    /// The sheet and the API always pass the default branch as the base. On
    /// a host, whose checkout nobody pulls, that has to mean what no base
    /// means there: origin's, freshly fetched, not the checkout's stale copy.
    func testOnAHostTheDefaultBranchAsBaseStartsFromOrigin() async throws {
        let runner = ProcessRunner()
        let clone = fixture.parent.appendingPathComponent("stale")
        _ = try await runner.runOrThrow(args: ["clone", "-q", fixture.repoURL.path, clone.path], cwd: fixture.parent)
        _ = try await runner.runOrThrow(args: ["commit", "--allow-empty", "-q", "-m", "newer"], cwd: fixture.repoURL)
        let newest = try await runner.runOrThrow(args: ["rev-parse", "HEAD"], cwd: fixture.repoURL).stdout
        var repo = fixture.repo
        repo.localMainPath = clone.path

        let path = try await WorktreeManager(site: RefreshingSite())
            .ensure(repo: repo, branch: "claude-fresh", baseRef: "main")

        let head = try await runner.runOrThrow(args: ["rev-parse", "HEAD"], cwd: path).stdout
        XCTAssertEqual(head, newest)
    }

    // MARK: - Helpers

    private func cloneWithoutLocalMain(remote: String = "origin") async throws -> URL {
        let runner = ProcessRunner()
        let clone = fixture.parent.appendingPathComponent("clone-\(remote)")
        _ = try await runner.runOrThrow(
            args: ["clone", "-q", "-o", remote, fixture.repoURL.path, clone.path], cwd: fixture.parent
        )
        _ = try await runner.runOrThrow(args: ["checkout", "-q", "-b", "elsewhere"], cwd: clone)
        _ = try await runner.runOrThrow(args: ["branch", "-D", "main"], cwd: clone)
        return clone
    }

    private func currentBranch(_ path: URL) async throws -> String {
        try await ProcessRunner().runOrThrow(args: ["branch", "--show-current"], cwd: path)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// This Mac's site with a host's policy: the default branch is fetched fresh.
private struct RefreshingSite: WorktreeSite {
    private let local = LocalWorktreeSite()
    let allowsMainCheckout = false
    let refreshesDefaultBranch = true

    func mainPath(for repo: Repo) -> String? {
        local.mainPath(for: repo)
    }

    func prepareWorktreesDir(mainURL: URL) async throws {
        try await local.prepareWorktreesDir(mainURL: mainURL)
    }

    func lock(worktreesDir: URL) async throws -> WorktreeLock {
        try await local.lock(worktreesDir: worktreesDir)
    }

    func canonicalPath(_ url: URL) -> String {
        local.canonicalPath(url)
    }

    func removeLeftover(at url: URL) async {
        await local.removeLeftover(at: url)
    }
}
