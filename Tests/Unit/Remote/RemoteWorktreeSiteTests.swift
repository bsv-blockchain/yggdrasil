import XCTest
@testable import Yggdrasil

/// Runs `WorktreeManager` with the remote site, but with a plain local runner
/// standing in for ssh: the commands the site sends are exactly what would run
/// on the host. The repo has no local clone (`localMainPath` nil); its path
/// comes from the host's repos root.
final class RemoteWorktreeSiteTests: XCTestCase {
    private var root: URL!
    private var host: RemoteHost!
    private let repo = Repo(
        id: 1, owner: "acme", name: "widget", defaultBranch: "main", localMainPath: nil, addedAt: Date()
    )

    private var mainURL: URL {
        root.appendingPathComponent("acme/widget", isDirectory: true)
    }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ygg-remote-site-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath() // /var → /private/var, as git reports it
        try FileManager.default.createDirectory(at: mainURL, withIntermediateDirectories: true)
        let git = ProcessRunner()
        _ = try await git.runOrThrow(args: ["init", "-b", "main"], cwd: mainURL)
        _ = try await git.runOrThrow(args: ["config", "user.email", "t@example.com"], cwd: mainURL)
        _ = try await git.runOrThrow(args: ["config", "user.name", "t"], cwd: mainURL)
        _ = try await git.runOrThrow(args: ["commit", "--allow-empty", "-m", "init"], cwd: mainURL)
        host = RemoteHost(id: 1, name: "h", sshTarget: "h", reposRoot: root.path, createdAt: Date())
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Runs bare command names on PATH, like `ygg run` on the host does.
    private struct PathRunner: SubprocessRunner {
        func run(executable: String, arguments: [String]) async throws -> SubprocessResult {
            try await ProcessRunner().run(executable: "/usr/bin/env", arguments: [executable] + arguments)
        }
    }

    private func manager(runner: SubprocessRunner = PathRunner()) -> WorktreeManager {
        WorktreeManager(
            git: GitRunner(runner: runner, gitExecutable: "git"),
            site: RemoteWorktreeSite(host: host, runner: runner)
        )
    }

    func testMainPathComesFromHostReposRoot() {
        XCTAssertEqual(RemoteWorktreeSite(host: host).mainPath(for: repo), mainURL.path)
    }

    func testEnsureCreatesWorktreeUnderHostRepo() async throws {
        let path = try await manager().ensure(repo: repo, branch: "feat/foo")
        XCTAssertEqual(path.path, mainURL.appendingPathComponent(".worktrees/feat-foo").path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.appendingPathComponent(".git").path))
    }

    func testEnsureIsIdempotentAndExcludesWorktreesDirOnce() async throws {
        let first = try await manager().ensure(repo: repo, branch: "feat/foo")
        let second = try await manager().ensure(repo: repo, branch: "feat/foo")
        XCTAssertEqual(first, second)
        let exclude = try String(
            contentsOf: mainURL.appendingPathComponent(".git/info/exclude"), encoding: .utf8
        )
        XCTAssertEqual(exclude.components(separatedBy: "\n").filter { $0 == ".worktrees/" }.count, 1, exclude)
    }

    func testRemoveUsesHostRepoPath() async throws {
        let manager = manager()
        let path = try await manager.ensure(repo: repo, branch: "feat/gone")
        try await manager.remove(repo: repo, path: path, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }

    func testEnsureClonedSkipsExistingCheckout() async throws {
        let cloned = try await RemoteWorktreeSite(host: host, runner: PathRunner()).ensureCloned(repo)
        XCTAssertFalse(cloned)
    }

    func testEnsureClonedRunsGhRepoCloneIntoHostPath() async throws {
        let stub = StubSubprocessRunner(responses: [SubprocessResult(stdout: "cloned\n", stderr: "", exitCode: 0)])
        let missing = RemoteHost(id: 2, name: "h", sshTarget: "h", reposRoot: "/srv/src", createdAt: Date())
        let cloned = try await RemoteWorktreeSite(host: missing, runner: stub).ensureCloned(repo)
        XCTAssertTrue(cloned)
        let calls = await stub.recordedCalls()
        XCTAssertEqual(calls.first?.executable, "sh")
        XCTAssertEqual(Array(calls.first?.arguments.suffix(3) ?? []), ["sh", "/srv/src/acme/widget", "acme/widget"])
    }

    func testEnsureClonedSurfacesCloneFailure() async {
        let stub = StubSubprocessRunner(responses: [
            SubprocessResult(stdout: "", stderr: "gh: not logged in", exitCode: 1)
        ])
        do {
            _ = try await RemoteWorktreeSite(host: host, runner: stub).ensureCloned(repo)
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? WorktreeError, .gitFailed(stderr: "gh: not logged in", exitCode: 1))
        }
    }

    func testCheckoutPathComesFromInjectedLookup() {
        let site = RemoteWorktreeSite(host: host, checkoutPath: { _ in "/pinned/widget" })
        XCTAssertEqual(site.mainPath(for: repo), "/pinned/widget")
    }

    func testRefusesToRunATabInTheMainCheckout() async throws {
        // Sessions only ever work in worktrees: asking for the branch the main
        // checkout is on must not hand back the main checkout itself.
        do {
            _ = try await manager().ensure(repo: repo, branch: "main")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? WorktreeError, .branchInMainCheckout("main"))
        }
    }

    func testNewBranchStartsFromFreshlyFetchedDefaultBranchWithoutTracking() async throws {
        // The host's checkout is only ever touched by the app, so nothing else
        // keeps its main current: a tab opened weeks after the clone must not
        // start from clone-day main.
        let upstream = root.appendingPathComponent("upstream", isDirectory: true)
        let git = ProcessRunner()
        _ = try await git.runOrThrow(args: ["clone", "-q", mainURL.path, upstream.path], cwd: root)
        _ = try await git.runOrThrow(args: ["remote", "add", "origin", upstream.path], cwd: mainURL)
        _ = try await git.runOrThrow(args: ["fetch", "-q", "origin"], cwd: mainURL)
        _ = try await git.runOrThrow(
            args: ["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "merged later"],
            cwd: upstream
        )
        let latest = try await git.runOrThrow(args: ["rev-parse", "HEAD"], cwd: upstream).stdout

        let path = try await manager().ensure(repo: repo, branch: "feat/fresh")
        let head = try await git.runOrThrow(args: ["rev-parse", "HEAD"], cwd: path).stdout
        XCTAssertEqual(head, latest)
        let upstreamOfBranch = try await ProcessRunner().run(
            executable: "/usr/bin/git", arguments: ["-C", path.path, "rev-parse", "--abbrev-ref", "@{upstream}"]
        )
        XCTAssertNotEqual(upstreamOfBranch.exitCode, 0, "must not track origin/main: \(upstreamOfBranch.stdout)")
    }
}
