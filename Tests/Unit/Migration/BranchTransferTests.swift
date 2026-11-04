import XCTest
@testable import Yggdrasil

/// Moving a tab's branch between two checkouts of one repo. "Remote" here is
/// a second local clone reached by path: the git is identical to the ssh case,
/// only the URL and runner differ.
final class BranchTransferTests: XCTestCase {
    private var root: URL!
    private var source: URL!
    private var dest: URL!
    private let git = GitRunner()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ygg-transfer-\(UUID().uuidString.prefix(8))", isDirectory: true)
            .resolvingSymlinksInPath()
        source = root.appendingPathComponent("source")
        dest = root.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try await run(["init", "-q", "-b", "main"], in: source)
        try await commit("init", in: source)
        try await run(["clone", "-q", source.path, dest.path], in: root)
        try await run(["checkout", "-q", "-b", "feat/x"], in: source)
        try await commit("work 1", in: source)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func run(_ args: [String], in dir: URL) async throws -> String {
        try await git.run(args: args, cwd: dir).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit(_ message: String, in dir: URL) async throws {
        try await run(
            ["-c", "user.email=t@e", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", message],
            in: dir
        )
    }

    private func head(_ ref: String, in dir: URL) async throws -> String {
        try await run(["rev-parse", ref], in: dir)
    }

    func testPushThenAdoptCreatesTheBranchAtTheSameCommit() async throws {
        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let moved = try await head("refs/heads/feat/x", in: dest)
        let original = try await head("feat/x", in: source)
        XCTAssertEqual(moved, original)
    }

    func testAdoptRemovesTheScratchRef() async throws {
        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let refs = try await run(["for-each-ref", "refs/ygg/"], in: dest)
        XCTAssertEqual(refs, "")
    }

    func testAdoptFastForwardsAWorktreeThatHasTheBranchCheckedOut() async throws {
        // Coming back to a host that still has the tab's old worktree.
        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let worktree = root.appendingPathComponent("dest-wt")
        try await run(["worktree", "add", "-q", worktree.path, "feat/x"], in: dest)
        try await commit("work 2", in: source)

        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let moved = try await head("HEAD", in: worktree)
        let original = try await head("feat/x", in: source)
        XCTAssertEqual(moved, original)
    }

    func testDivergedBranchIsRefusedNotOverwritten() async throws {
        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let worktree = root.appendingPathComponent("dest-wt")
        try await run(["worktree", "add", "-q", worktree.path, "feat/x"], in: dest)
        try await commit("only on dest", in: worktree)
        let destOnly = try await head("HEAD", in: worktree)
        try await commit("only on source", in: source)

        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        do {
            try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? MigrationError, .branchDiverged("feat/x"))
        }
        let after = try await head("HEAD", in: worktree)
        XCTAssertEqual(after, destOnly, "the destination's own commit must survive")
    }

    func testFetchBringsTheBranchBackForAdoption() async throws {
        // The host → local direction: the receiving side pulls.
        try await BranchTransfer.fetch(branch: "feat/x", from: source.path, into: dest, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let moved = try await head("refs/heads/feat/x", in: dest)
        let original = try await head("feat/x", in: source)
        XCTAssertEqual(moved, original)
    }

    func testSSHURLAndCommandForAHost() {
        let host = RemoteHost(id: 1, name: "d", sshTarget: "me@dev", reposRoot: "/srv", createdAt: Date())
        XCTAssertEqual(BranchTransfer.url(host: host, path: "/srv/acme/widget"), "ssh://me@dev/srv/acme/widget")
        XCTAssertTrue(BranchTransfer.sshCommand.hasPrefix("/usr/bin/ssh -o ControlMaster=auto"))
        XCTAssertTrue(BranchTransfer.sshCommand.contains("-o BatchMode=yes"))
    }

    func testDirtyDestinationWorktreeIsRefused() async throws {
        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let worktree = root.appendingPathComponent("dest-wt")
        try await run(["worktree", "add", "-q", worktree.path, "feat/x"], in: dest)
        try "stale".write(to: worktree.appendingPathComponent("left-behind.txt"), atomically: true, encoding: .utf8)
        try await commit("work 2", in: source)

        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        do {
            try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
            XCTFail("expected a refusal")
        } catch {
            // git reports /private/var/…; Foundation spells it /var/….
            guard case let .dirtyWorktree(path)? = error as? MigrationError else { return XCTFail("\(error)") }
            XCTAssertTrue(path.hasSuffix("/dest-wt"), path)
        }
    }

    func testAWorktreeDeletedByHandDoesNotBlockAdopt() async throws {
        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let worktree = root.appendingPathComponent("dest-wt")
        try await run(["worktree", "add", "-q", worktree.path, "feat/x"], in: dest)
        try FileManager.default.removeItem(at: worktree) // rm -rf, no `git worktree remove`
        try await commit("work 2", in: source)

        try await BranchTransfer.push(branch: "feat/x", from: source, to: dest.path, git: git)
        try await BranchTransfer.adopt(branch: "feat/x", checkout: dest, git: git)
        let moved = try await head("refs/heads/feat/x", in: dest)
        let original = try await head("feat/x", in: source)
        XCTAssertEqual(moved, original)
    }

    func testIPv6TargetsAreBracketed() {
        let host = RemoteHost(id: 1, name: "d", sshTarget: "me@2001:db8::5", reposRoot: "/srv", createdAt: Date())
        XCTAssertEqual(BranchTransfer.url(host: host, path: "/srv/w"), "ssh://me@[2001:db8::5]/srv/w")
        XCTAssertEqual(host.scpHost, "me@[2001:db8::5]")
        let plain = RemoteHost(id: 2, name: "d", sshTarget: "dev", reposRoot: "/srv", createdAt: Date())
        XCTAssertEqual(plain.scpHost, "dev")
    }
}
