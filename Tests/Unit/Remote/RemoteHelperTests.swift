import XCTest
@testable import Yggdrasil

/// Runs the real `ygg` helper script under /bin/sh with a scratch HOME and
/// stub `dtach`/`claude`/login-shell binaries, so the session logic is
/// exercised end to end without a server or dtach installed.
final class RemoteHelperTests: XCTestCase {
    private var home: URL!
    private var bin: URL!
    private var loginBin: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("ygg-helper-\(UUID().uuidString.prefix(8))")
        bin = home.appendingPathComponent("stubs")
        loginBin = home.appendingPathComponent("loginbin")
        for dir in [bin!, loginBin!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Stub dtach. `-a`: record and exit. `-A`: hold a real unix socket for
        // as long as the wrapped command runs, as dtach does.
        try writeExecutable(bin, "dtach", """
        #!/bin/sh
        echo "$@" > "$HOME/dtach.args"
        mode=$1; sock=$2; shift 2
        [ "$mode" = -a ] && exit 0
        while [ "$1" = -E ] || [ "$1" = -z ] || [ "$1" = -r ]; do
            [ "$1" = -r ] && shift
            shift
        done
        /usr/bin/python3 -c 'import socket,sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$sock"
        "$@"; rc=$?
        rm -f "$sock"
        exit $rc
        """)
        // The user's login shell: `-l -i -c 'env; exit'` reports the PATH its
        // rc files set; `-l` alone is the interactive shell itself.
        try writeExecutable(bin, "loginshell", """
        #!/bin/sh
        if [ "$*" = "-l -i -c env; exit" ]; then echo "PATH=\(loginBin.path):/usr/bin:/bin"; exit 0; fi
        echo "$@" > "$HOME/shell.ran"
        """)
        // claude only exists on the login PATH, like ~/.local/bin installs.
        try writeExecutable(loginBin, "claude", """
        #!/bin/sh
        pwd > "$HOME/claude.cwd"
        echo "$@" > "$HOME/claude.args"
        [ -n "${YGG_TEST_SLEEP:-}" ] && exec sleep 30
        exit 0
        """)
        try RemoteHelper.script.write(to: home.appendingPathComponent("ygg"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeExecutable(_ dir: URL, _ name: String, _ body: String) throws {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    @discardableResult
    private func sh(_ command: String, env extra: [String: String] = [:]) throws -> SubprocessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = [
            "HOME": home.path, "SHELL": bin.appendingPathComponent("loginshell").path,
            "PATH": "\(bin.path):/usr/bin:/bin"
        ].merging(extra) { $1 }
        process.currentDirectoryURL = home
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return SubprocessResult(
            stdout: String(bytes: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(bytes: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    private func read(_ name: String) throws -> String {
        try String(contentsOf: home.appendingPathComponent(name), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relative).path)
    }

    private func ygg(_ args: String) -> String {
        "sh \"$HOME/ygg\" \(args)"
    }

    /// Starts a long-running agent for `tab` in the background and waits for
    /// its session (pid file + socket) to exist.
    private func startSleepingSession(tab: Int, cwd: String = "\"$HOME\"") throws {
        try sh(ygg("attach \(tab) \(cwd) -- claude >/dev/null 2>&1 &"), env: ["YGG_TEST_SLEEP": "1"])
        for _ in 0 ..< 100 where !(exists(".yggdrasil/sessions/\(tab).pid")
            && exists(".yggdrasil/sessions/\(tab).sock")) {
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    func testVersionMatchesSwiftConstant() throws {
        XCTAssertEqual(try sh(ygg("version")).stdout, "\(RemoteHelper.version)\n")
    }

    func testAttachRunsAgentFromLoginPathInCwdThroughTabSocket() throws {
        let work = home.appendingPathComponent("work dir")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let result = try sh(ygg("attach 7 '\(work.path)' -- claude --flag 'two words'"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try read("claude.args"), "--flag two words")
        XCTAssertEqual(try read("claude.cwd"), work.resolvingSymlinksInPath().path)
        XCTAssertTrue(try read("dtach.args")
            .hasPrefix("-A \(home.path)/.yggdrasil/sessions/7.sock -E -z -r winch /bin/sh"))
    }

    func testAttachLeavesTheTerminalToDtach() throws {
        // `$SHELL -l -i -c env` execs env, so the interactive shell never hands
        // the terminal back: dtach started in a background process group, got
        // no raw mode, and its first read ended the session. zsh shows it here
        // as bash 5 does on Linux. A stub dtach reports its group and the tty's.
        try writeExecutable(bin, "dtach", """
        #!/bin/sh
        echo "$(ps -o pgid= -p $$ | tr -d ' ') $(ps -o tpgid= -p $$ | tr -d ' ')" > "$HOME/dtach.groups"
        """)
        try writeExecutable(home, "inpty", """
        #!/usr/bin/python3
        import os, pty, signal, sys
        signal.alarm(20)  # a shell stuck on the terminal fails the test, not CI
        pid, fd = pty.fork()
        if pid == 0:
            os.execv(sys.argv[1], sys.argv[1:])
        while True:
            try:
                if not os.read(fd, 4096):
                    break
            except OSError:
                break
        os.waitpid(pid, 0)
        """)
        try sh("\"$HOME/inpty\" /bin/sh \"$HOME/ygg\" attach 7 \"$HOME\" -- claude", env: ["SHELL": "/bin/zsh"])
        let groups = try read("dtach.groups").split(separator: " ")
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first, groups.last, "dtach must own the terminal (pgid tpgid)")
    }

    func testAttachPinsNewClaudeSession() throws {
        try sh(ygg("attach 7 \"$HOME\" --claude-session abc -- claude --x"))
        XCTAssertEqual(try read("claude.args"), "--x --session-id abc")
    }

    func testAttachResumesWhenTranscriptExistsInAnyProjectDir() throws {
        let project = home.appendingPathComponent(".claude/projects/-elsewhere")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try "".write(to: project.appendingPathComponent("abc.jsonl"), atomically: true, encoding: .utf8)
        try sh(ygg("attach 7 \"$HOME\" --claude-session abc -- claude --x"))
        XCTAssertEqual(try read("claude.args"), "--x --resume abc")
    }

    func testAttachWithoutCommandRunsUsersLoginShell() throws {
        let result = try sh(ygg("attach 5 \"$HOME\" --"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try read("shell.ran"), "-l")
    }

    func testAttachRejectsNonNumericTab() throws {
        let result = try sh(ygg("attach '../x' \"$HOME\" -- claude"))
        XCTAssertEqual(result.exitCode, 2)
        XCTAssertFalse(exists("claude.args"))
    }

    func testReattachToLiveSessionDoesNotNeedTheWorktree() throws {
        let work = home.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try startSleepingSession(tab: 8, cwd: "'\(work.path)'")
        try FileManager.default.removeItem(at: work)

        let result = try sh(ygg("attach 8 '\(work.path)' -- claude"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try read("dtach.args"), "-a \(home.path)/.yggdrasil/sessions/8.sock -E -z -r winch")
        try sh(ygg("kill 8"))
    }

    func testAliveListAndKillTrackTheAgentProcess() throws {
        try startSleepingSession(tab: 9)
        XCTAssertEqual(try sh(ygg("alive 9")).exitCode, 0)
        XCTAssertEqual(try sh(ygg("list")).stdout, "9\n")

        XCTAssertEqual(try sh(ygg("kill 9")).exitCode, 0)
        XCTAssertEqual(try sh(ygg("alive 9")).exitCode, 1)
        XCTAssertEqual(try sh(ygg("list")).stdout, "")
        XCTAssertFalse(exists(".yggdrasil/sessions/9.sock"), "kill must wait for dtach to drop the socket")
    }

    func testStalePidFileNeverKillsAnUnrelatedProcess() throws {
        // The agent exited on its own (socket gone) and its pid now belongs
        // to something else.
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep")
        bystander.arguments = ["30"]
        try bystander.run()
        defer { bystander.terminate() }
        let sessions = home.appendingPathComponent(".yggdrasil/sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try "\(bystander.processIdentifier)".write(
            to: sessions.appendingPathComponent("3.pid"), atomically: true, encoding: .utf8
        )

        XCTAssertEqual(try sh(ygg("alive 3")).exitCode, 1)
        XCTAssertEqual(try sh(ygg("list")).stdout, "")
        XCTAssertEqual(try sh(ygg("kill 3")).exitCode, 0)
        XCTAssertTrue(bystander.isRunning)
        XCTAssertFalse(exists(".yggdrasil/sessions/3.pid"))
    }

    func testKillOfUnknownTabSucceeds() throws {
        XCTAssertEqual(try sh(ygg("kill 404")).exitCode, 0)
    }

    func testCheckReportsToolsMissingFromLoginPath() throws {
        // claude only on the login PATH, dtach only on ssh's own, gh (Homebrew)
        // on neither: both PATHs count.
        let result = try sh(ygg("check"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertFalse(result.stdout.contains("missing:claude"), result.stdout)
        XCTAssertFalse(result.stdout.contains("missing:dtach"), result.stdout)
        XCTAssertTrue(result.stdout.contains("missing:gh"), result.stdout)
    }

    func testEnsureCurrentReplacesAStaleHelper() throws {
        // A host set up by an older app keeps its helper until something
        // reinstalls it; tab spawns run this first so an update reaches it.
        try sh("mkdir -p ~/.yggdrasil/bin")
        try writeExecutable(home, ".yggdrasil/bin/ygg", "#!/bin/sh\necho 1\n")
        try sh(RemoteHelper.ensureCurrentCommand)
        XCTAssertEqual(try sh("~/.yggdrasil/bin/ygg version").stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                       String(RemoteHelper.version))
    }

    func testEnsureCurrentLeavesTheCurrentHelperAlone() throws {
        try sh(RemoteHelper.installCommand)
        try sh("touch -t 200001010000 ~/.yggdrasil/bin/ygg")
        try sh(RemoteHelper.ensureCurrentCommand)
        XCTAssertEqual(
            try sh("date -r ~/.yggdrasil/bin/ygg +%Y").stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            "2000",
            "not rewritten"
        )
    }

    func testFailedInstallLeavesNoTempFile() throws {
        // base64 failing (disk full, quota) after the temp file was created.
        try writeExecutable(bin, "base64", "#!/bin/sh\nexit 1\n")
        let result = try sh(RemoteHelper.installCommand)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".yggdrasil/bin").path),
            []
        )
    }

    func testInstallCommandWritesExecutableHelper() throws {
        let result = try sh(RemoteHelper.installCommand)
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try sh("\"$HOME/.yggdrasil/bin/ygg\" version").stdout, "\(RemoteHelper.version)\n")
    }

    func testRunExecsCommandWithLoginPath() throws {
        let result = try sh(ygg("run -- claude --version"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try read("claude.args"), "--version")
    }

    func testRunPassesExitStatusThrough() throws {
        XCTAssertEqual(try sh(ygg("run -- sh -c 'exit 7'")).exitCode, 7)
    }

    func testRunReusesCachedLoginPath() throws {
        // The login shell can be slow (nvm & co.); `run` is called for every
        // git command, so it reads the PATH that check/attach cached.
        try sh(ygg("check"))
        try FileManager.default.removeItem(at: bin.appendingPathComponent("loginshell"))
        let result = try sh(ygg("run -- claude --cached"))
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try read("claude.args"), "--cached")
    }
}
