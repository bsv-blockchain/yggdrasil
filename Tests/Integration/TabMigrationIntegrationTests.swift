import XCTest
@testable import Yggdrasil

/// Moves a tab this Mac → host → this Mac through the live migration steps:
/// real git over ssh, real worktrees, real scp of the transcript. Agent
/// processes aren't involved (no terminal is mounted). Guarded by
/// YGGDRASIL_TEST_SSH_HOST, like RemoteHostIntegrationTests.
@MainActor
final class TabMigrationIntegrationTests: XCTestCase {
    /// Far above real tab ids: the move runs `ygg kill <id>` on the host.
    private let tabID: Int64 = 990_003
    private let sessionID = UUID().uuidString.lowercased()
    private var target: String!
    private var local: URL!
    private var remoteRoot: String?

    override func setUpWithError() throws {
        guard let target = ProcessInfo.processInfo.environment["YGGDRASIL_TEST_SSH_HOST"], !target.isEmpty else {
            throw XCTSkip("YGGDRASIL_TEST_SSH_HOST not set")
        }
        self.target = target
        local = FileManager.default.temporaryDirectory
            .appendingPathComponent("ygg-migrate-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
    }

    override func tearDown() async throws {
        if let remoteRoot {
            _ = try? await remote("rm -rf -- '\(remoteRoot)'; rm -f \"$HOME\"/.claude/projects/*/\(sessionID).jsonl")
        }
        if let local { try? FileManager.default.removeItem(at: local) }
    }

    @discardableResult
    private func remote(_ script: String) async throws -> String {
        let host = RemoteHost(id: 0, name: "", sshTarget: target, reposRoot: "/", createdAt: Date())
        let result = try await SSHSubprocessRunner(host: host).run(executable: "sh", arguments: ["-c", script])
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) async throws -> String {
        try await GitRunner().run(args: ["-c", "user.email=t@e", "-c", "user.name=t"] + args, cwd: dir)
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local clone with a tab worktree on feat/it, one commit ahead of main.
    private func makeLocalClone() async throws -> (main: URL, worktree: URL) {
        let main = local.appendingPathComponent("acme/widget", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try await git(["init", "-q", "-b", "main"], in: main)
        try await git(["commit", "-q", "--allow-empty", "-m", "init"], in: main)
        let worktree = main.appendingPathComponent(".worktrees/feat-it", isDirectory: true)
        try await git(["worktree", "add", "-q", "-b", "feat/it", worktree.path], in: main)
        try await git(["commit", "-q", "--allow-empty", "-m", "local work"], in: worktree)
        return (main, worktree)
    }

    /// The host's checkout of the same repo, as `gh repo clone` would leave it.
    private func makeHostCheckout(pushing main: URL) async throws -> (root: String, checkout: String) {
        let root = try await remote("mktemp -d /tmp/ygg-it-migrate.XXXXXX")
        remoteRoot = root
        let checkout = "\(root)/acme/widget"
        try await remote(
            "mkdir -p \(checkout) && git -C \(checkout) init -q -b main && git -C \(checkout) config receive.denyCurrentBranch updateInstead"
        )
        try await git(["push", "-q", "ssh://\(target!)\(checkout)", "main"], in: main)
        return (root, checkout)
    }

    /// A conversation for the tab in a scratch home; returns that home.
    private func writeTranscript(for worktree: URL) throws -> URL {
        let home = local.appendingPathComponent("home", isDirectory: true)
        let projectDir = AgentSessionLocator.projectDirectory(forWorktreePath: worktree.path, home: home.path)
        try FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)
        try "{\"marker\":\"\(sessionID)\"}\n".write(
            toFile: "\(projectDir)/\(sessionID).jsonl", atomically: true, encoding: .utf8
        )
        return home
    }

    func testRoundTripMovesBranchWorktreeAndConversation() async throws {
        _ = try await RemoteSessionControl().preflight(host: RemoteHost(
            id: 0, name: "", sshTarget: target, reposRoot: "/", createdAt: Date()
        ))
        let (main, worktree) = try await makeLocalClone()
        let localWork = try await git(["rev-parse", "HEAD"], in: worktree)
        let (root, checkout) = try await makeHostCheckout(pushing: main)
        let home = try writeTranscript(for: worktree)

        let services = try AppServices(database: YggdrasilDatabase.inMemory())
        let host = try services.hostStore.add(name: "it", sshTarget: target, reposRoot: root)
        let tabID = tabID
        let repo = try await services.database.queue.write { db -> Repo in
            var repo = Repo(
                id: nil, owner: "acme", name: "widget", defaultBranch: "main", localMainPath: main.path, addedAt: Date()
            )
            try repo.insert(db)
            var tab = YggdrasilTab(
                id: tabID, taskID: nil, codingAgentID: nil, position: 0, branchName: "feat/it",
                worktreePath: worktree.path, lastMainView: .agent, createdAt: Date(), lastActiveAt: Date()
            )
            try tab.insert(db)
            return repo
        }
        _ = try services.sessionStore.start(
            tabID: tabID,
            cwd: worktree.path,
            command: "claude",
            args: [],
            claudeSessionID: sessionID
        )
        let transcripts = TranscriptTransfer(home: home.path)
        let environment = TabMigrator.live(tabID: tabID, services: services, transcripts: transcripts)

        // This Mac → host.
        let remotePath = try await TabMigrator(environment: environment).migrate(.init(
            tabID: tabID, repo: repo, branch: "feat/it", sessionID: sessionID,
            source: nil, sourcePath: worktree.path, destination: host
        ))
        XCTAssertEqual(remotePath, "\(checkout)/.worktrees/feat-it")
        let remoteHead = try await remote("git -C \(remotePath) rev-parse HEAD")
        XCTAssertEqual(remoteHead, localWork)
        let encoded = AgentSessionLocator.encode(cwd: remotePath)
        let remoteTranscript = try await remote("cat \"$HOME/.claude/projects/\(encoded)/\(sessionID).jsonl\"")
        XCTAssertTrue(remoteTranscript.contains(sessionID))
        var row = try XCTUnwrap(try services.tabStore.get(id: tabID))
        XCTAssertEqual(row.hostID, host.id)
        XCTAssertEqual(row.worktreePath, remotePath)
        XCTAssertTrue(row.isReady)

        // Work continues on the host, then the tab comes home.
        try await remote("git -C \(remotePath) -c user.email=t@e -c user.name=t commit -q --allow-empty -m 'host work'")
        let hostWork = try await remote("git -C \(remotePath) rev-parse HEAD")
        let back = try await TabMigrator(environment: environment).migrate(.init(
            tabID: tabID, repo: repo, branch: "feat/it", sessionID: sessionID,
            source: host, sourcePath: remotePath, destination: nil
        ))
        XCTAssertEqual(back, worktree.path, "the original local worktree is reused")
        let localHead = try await git(["rev-parse", "HEAD"], in: worktree)
        XCTAssertEqual(localHead, hostWork, "fast-forwarded to the host's commit")
        row = try XCTUnwrap(try services.tabStore.get(id: tabID))
        XCTAssertNil(row.hostID)
        XCTAssertEqual(row.worktreePath, worktree.path)
        XCTAssertNotNil(TranscriptTransfer.localTranscript(sessionID: sessionID, home: home.path))
    }
}
