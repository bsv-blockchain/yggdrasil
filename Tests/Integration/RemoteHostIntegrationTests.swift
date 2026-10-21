import XCTest
@testable import Yggdrasil

/// Drives a real ssh host through the app's remote code: preflight (installs
/// the helper), attach, detach, reattach, a dropped connection, kill, and a
/// real claude launch. Guarded by YGGDRASIL_TEST_SSH_HOST (an ssh target the
/// user's ssh config can reach without prompting, with dtach and claude on
/// it). Through xcodebuild, pass it as TEST_RUNNER_YGGDRASIL_TEST_SSH_HOST.
final class RemoteHostIntegrationTests: XCTestCase {
    /// Tab ids far above anything a real database hands out.
    private let shellTab: Int64 = 990_001
    private let claudeTab: Int64 = 990_002
    private var host: RemoteHost!
    private var launched: [Process] = []

    override func setUpWithError() throws {
        guard let target = ProcessInfo.processInfo.environment["YGGDRASIL_TEST_SSH_HOST"], !target.isEmpty else {
            throw XCTSkip("YGGDRASIL_TEST_SSH_HOST not set")
        }
        host = RemoteHost(id: 1, name: "it", sshTarget: target, reposRoot: "/tmp", createdAt: Date())
    }

    override func tearDown() async throws {
        for process in launched where process.isRunning {
            process.terminate()
        }
        if host != nil {
            for tab in [shellTab, claudeTab] {
                try? await RemoteSessionControl().kill(host: host, tabID: tab)
            }
        }
    }

    // MARK: - Helpers

    /// Runs a POSIX sh snippet on the host; returns (exit code, stdout).
    private func remote(_ script: String) async throws -> (Int32, String) {
        let result = try await ProcessRunner().run(
            executable: SSHCommand.executable,
            arguments: SSHCommand.exec(
                target: host.sshTarget, remoteCommand: SSHCommand.posixRemote(script),
                controlDirectory: SSHCommand.defaultControlDirectory
            )
        )
        return (result.exitCode, result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func alive(_ tab: Int64) async throws -> Bool {
        try await remote("\(RemoteHelper.path) alive \(tab)").0 == 0
    }

    /// Starts the tab's terminal process the way AgentTerminalSurface does,
    /// minus the PTY: `-tt` forces one on the host side regardless.
    private func attach(_ tab: Int64, command: String, args: [String], cwd: String = "/tmp") throws -> Process {
        let spawn = RemoteSpawn.make(
            host: host,
            session: OpenSession(id: tab, displayName: "it", cwd: cwd, command: command, args: args),
            storedSessionID: nil, newSessionID: "00000000-0000-4000-8000-0000000000aa", colorfgbg: "15;0"
        )
        SSHCommand.prepareControlDirectory()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: spawn.executable)
        process.arguments = spawn.args
        process.standardInput = Pipe() // held open, like a terminal
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        launched.append(process)
        return process
    }

    private func waitUntil(_ timeout: TimeInterval, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return try await condition()
    }

    private func exitStatus(of process: Process, within timeout: TimeInterval) async -> Int32? {
        let exited = await waitUntil(timeout) { !process.isRunning }
        return exited ? process.terminationStatus : nil
    }

    // MARK: - Tests

    func testPreflightInstallsHelperAndFindsTools() async throws {
        let report = try await RemoteSessionControl().preflight(host: host)
        XCTAssertEqual(report.missingTools, [], "host is missing tools")
        let (code, version) = try await remote("\(RemoteHelper.path) version")
        XCTAssertEqual(code, 0)
        XCTAssertEqual(version, String(RemoteHelper.version))
    }

    func testSessionSurvivesDetachAndDropAndEndsOnKill() async throws {
        _ = try await RemoteSessionControl().preflight(host: host)
        let agent = ["-c", "echo started; exec sleep 600"]

        // Attach creates the session.
        let first = try attach(shellTab, command: "/bin/sh", args: agent)
        let started = try await waitUntil(15) { try await alive(shellTab) }
        XCTAssertTrue(started, "session never came up")

        // Detach: the app closing the view or quitting kills only local ssh.
        first.terminate()
        _ = await exitStatus(of: first, within: 10)
        let survivedDetach = try await alive(shellTab)
        XCTAssertTrue(survivedDetach, "agent died with the ssh client")

        // A dropped connection (shared connection closed) is ssh exit 255 → reconnect.
        let second = try attach(shellTab, command: "/bin/sh", args: agent)
        try? await Task.sleep(for: .seconds(2))
        XCTAssertTrue(second.isRunning, "reattach exited early")
        let closeConnection = Process()
        closeConnection.executableURL = URL(fileURLWithPath: SSHCommand.executable)
        closeConnection.arguments = SSHCommand.options(controlDirectory: SSHCommand.defaultControlDirectory)
            + ["-O", "exit", "--", host.sshTarget]
        closeConnection.standardError = FileHandle.nullDevice
        try closeConnection.run()
        closeConnection.waitUntilExit()
        let dropStatus = await exitStatus(of: second, within: 15)
        XCTAssertEqual(dropStatus.map(ReconnectPolicy.exitStatus), 255, "drop must look like a transport failure")
        XCTAssertTrue(ReconnectPolicy.shouldReconnect(isRemote: true, exitCode: dropStatus))
        let survivedDrop = try await alive(shellTab)
        XCTAssertTrue(survivedDrop, "agent died with the connection")

        // Kill ends the agent; an attached client then exits without 255,
        // so the tab shows the exit banner instead of reconnecting.
        let third = try attach(shellTab, command: "/bin/sh", args: agent)
        try? await Task.sleep(for: .seconds(2))
        try await RemoteSessionControl().kill(host: host, tabID: shellTab)
        let isAlive = try await alive(shellTab)
        XCTAssertFalse(isAlive)
        let killStatus = await exitStatus(of: third, within: 15)
        XCTAssertNotNil(killStatus, "attached client didn't exit after kill")
        XCTAssertFalse(
            ReconnectPolicy.shouldReconnect(isRemote: true, exitCode: killStatus),
            "\(String(describing: killStatus))"
        )
    }

    func testClaudeStartsFromLoginPathWithPinnedSession() async throws {
        _ = try await RemoteSessionControl().preflight(host: host)
        let (_, cwd) = try await remote("mktemp -d /tmp/ygg-it.XXXXXX")
        _ = try attach(claudeTab, command: "claude", args: [], cwd: cwd)
        let started = try await waitUntil(20) { try await alive(claudeTab) }
        XCTAssertTrue(started, "claude never came up")

        let (_, args) = try await remote("ps -o args= -p \"$(cat ~/.yggdrasil/sessions/\(claudeTab).pid)\"")
        XCTAssertTrue(args.contains("claude"), args)
        XCTAssertTrue(args.contains("--session-id 00000000-0000-4000-8000-0000000000aa"), args)
        let (_, procCwd) = try await remote("readlink /proc/\"$(cat ~/.yggdrasil/sessions/\(claudeTab).pid)\"/cwd")
        XCTAssertEqual(procCwd, cwd)

        try await RemoteSessionControl().kill(host: host, tabID: claudeTab)
        _ = try await remote("rmdir \(cwd)")
    }

    func testWorktreesOnHostShareOneCheckoutAndNeverUseIt() async throws {
        _ = try await RemoteSessionControl().preflight(host: host)
        let (_, root) = try await remote("mktemp -d /tmp/ygg-it-repos.XXXXXX")
        let repo = Repo(
            id: 1,
            owner: "acme",
            name: "widget",
            defaultBranch: "main",
            localMainPath: nil,
            addedAt: Date()
        )
        let checkout = "\(root)/acme/widget"
        let (initCode, _) = try await remote("""
        mkdir -p \(checkout) && cd \(checkout) && git init -q -b main && \
        git -c user.email=t@e -c user.name=t commit -q --allow-empty -m init
        """)
        XCTAssertEqual(initCode, 0)
        let site = RemoteWorktreeSite(host: host, checkoutPath: { _ in checkout })
        let manager = WorktreeManager(git: GitRunner(runner: site.runner, gitExecutable: "git"), site: site)

        let first = try await manager.ensure(repo: repo, branch: "feat/a")
        let second = try await manager.ensure(repo: repo, branch: "feat/b")
        XCTAssertEqual(first.path, "\(checkout)/.worktrees/feat-a")
        XCTAssertEqual(second.path, "\(checkout)/.worktrees/feat-b")
        let again = try await manager.ensure(repo: repo, branch: "feat/a")
        XCTAssertEqual(again, first)
        let (_, worktrees) = try await remote("git -C \(checkout) worktree list | wc -l")
        XCTAssertEqual(worktrees, "3", "one checkout + two worktrees")
        let (_, excluded) = try await remote("grep -cxF .worktrees/ \(checkout)/.git/info/exclude")
        XCTAssertEqual(excluded, "1")
        do {
            _ = try await manager.ensure(repo: repo, branch: "main")
            XCTFail("a tab must never get the main checkout")
        } catch {
            XCTAssertEqual(error as? WorktreeError, .branchInMainCheckout("main"))
        }

        try await manager.remove(repo: repo, path: first, force: true)
        let (gone, _) = try await remote("test -e \(first.path)")
        XCTAssertNotEqual(gone, 0)
        _ = try await remote("rm -rf -- '\(root)'")
    }

    func testEnsureClonedUsesHostGhOnceThenReusesCheckout() async throws {
        _ = try await RemoteSessionControl().preflight(host: host)
        let (_, root) = try await remote("mktemp -d /tmp/ygg-it-clone.XXXXXX")
        let repo = Repo(
            id: 1, owner: "octocat", name: "Hello-World", defaultBranch: "master", localMainPath: nil, addedAt: Date()
        )
        let site = RemoteWorktreeSite(host: host, checkoutPath: { _ in "\(root)/octocat/Hello-World" })
        let clonedFirst = try await site.ensureCloned(repo)
        XCTAssertTrue(clonedFirst)
        let clonedAgain = try await site.ensureCloned(repo)
        XCTAssertFalse(clonedAgain)
        let (code, _) = try await remote("test -d \(root)/octocat/Hello-World/.git")
        XCTAssertEqual(code, 0)
        _ = try await remote("rm -rf -- '\(root)'")
    }
}
