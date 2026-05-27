import Darwin
import Foundation
import SwiftTerm

/// Manages the lifecycle of a single coding-agent process in a tab.
///
/// Wraps `SwiftTerm.LocalProcess` so the same instance can be hooked up to a
/// `SwiftTerm.LocalProcessTerminalView` for rendering in production while
/// remaining unit-testable headlessly (Task 5 adds the view wrapper).
///
/// Responsibilities per spec §Phase 3:
/// - Spawn `<command> <args>` inside a PTY at `cwd`, no interactive shell wrapper.
/// - Capture last 4KB of agent output into an `OutputRingBuffer` (used by Phase 6).
/// - Persist `session_state` rows: a row at start, exit code + ptyEndedAt at end.
/// - Clean shutdown via `terminate(graceful:)` — SIGTERM, then SIGKILL after 5s.
final class CodingAgentRunner: NSObject, @unchecked Sendable {

    let tabID: Int64
    let cwd: String
    let command: String
    let args: [String]
    private let sessionStore: SessionStateStore
    private let killAfter: Duration

    private let stateLock = NSLock()
    private var ring = OutputRingBuffer.makeAgentOutputRing()
    private var exitCode: Int32?
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []

    /// `LocalProcess.shellPid` is the PTY child's PID once started. Capture it so we
    /// can `kill(SIGTERM/SIGKILL)` from `terminate()`.
    private var pid: pid_t = 0
    private var localProcess: LocalProcess?

    init(
        tabID: Int64,
        cwd: String,
        command: String,
        args: [String],
        sessionStore: SessionStateStore,
        killAfter: Duration = .seconds(5)
    ) {
        self.tabID = tabID
        self.cwd = cwd
        self.command = command
        self.args = args
        self.sessionStore = sessionStore
        self.killAfter = killAfter
        super.init()
    }

    // MARK: - Lifecycle

    func start() throws {
        // Persist session_state ahead of the actual spawn so a crash mid-spawn leaves
        // a tombstone row a restart can see.
        _ = try sessionStore.start(tabID: tabID, cwd: cwd, command: command, args: args)

        let process = LocalProcess(delegate: self)
        self.localProcess = process

        // SwiftTerm.LocalProcess doesn't accept a cwd parameter, and we don't want to
        // mutate the parent process's working directory (race-prone with concurrent
        // runners). The minimal wrapper that sets cwd without spawning an interactive
        // shell: `/bin/sh -c 'cd "<cwd>" && exec <cmd> <args...>'`. `exec` replaces
        // the shell so signals reach the agent directly, and `/bin/sh` reads no
        // user rc files. Spec §2.1 forbids interactive shell wrappers — this is non-
        // interactive.
        let quotedCwd = CodingAgentRunner.shellQuote(cwd)
        let quotedCmd = CodingAgentRunner.shellQuote(command)
        let quotedArgs = args.map(CodingAgentRunner.shellQuote).joined(separator: " ")
        let cdAndExec = "cd \(quotedCwd) && exec \(quotedCmd) \(quotedArgs)"
        // Spawn through the user's login shell (-l) so .zprofile/.bash_profile run
        // and the agent inherits the same PATH the user has in Terminal. Apps
        // launched from Finder/`open` start with a stripped /usr/bin:/bin PATH;
        // without this, commands like `claude` (typically installed under
        // ~/.claude/local/bin or /opt/homebrew/bin) fail with exit code 127.
        // -l is a login shell but -c keeps it non-interactive, satisfying §2.1.
        let loginShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        process.startProcess(executable: loginShell, args: ["-l", "-c", cdAndExec])
        pid = process.shellPid
    }

    /// `graceful == true` sends SIGTERM and (after `killAfter`) SIGKILL if needed.
    /// `graceful == false` sends SIGKILL immediately.
    func terminate(graceful: Bool) {
        let targetPid = pid
        guard targetPid > 0 else { return }
        if graceful {
            kill(targetPid, SIGTERM)
            // Schedule the SIGKILL fallback. If the process exits cleanly the kill is
            // a no-op (ESRCH on a dead pid).
            Task { [killAfter] in
                try? await Task.sleep(for: killAfter)
                if self.lastExitCode == nil {
                    kill(targetPid, SIGKILL)
                }
            }
        } else {
            kill(targetPid, SIGKILL)
        }
    }

    /// Blocks the caller until the process has exited (or `timeout` elapses).
    func waitUntilExited(timeout: Duration) async throws {
        if lastExitCode != nil { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.appendExitWaiter(continuation)
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw RunnerError.waitTimedOut
            }
            try await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Captured output (Phase 6 fallback status detection)

    func capturedOutput() -> Data {
        stateLock.lock(); defer { stateLock.unlock() }
        return ring.contents()
    }

    var lastExitCode: Int32? {
        stateLock.lock(); defer { stateLock.unlock() }
        return exitCode
    }

    // MARK: - Internals

    private func appendExitWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        stateLock.lock()
        if exitCode != nil {
            stateLock.unlock()
            continuation.resume()
        } else {
            exitWaiters.append(continuation)
            stateLock.unlock()
        }
    }

    private func recordExit(code: Int32?) {
        stateLock.lock()
        let resolvedCode = code ?? -1
        exitCode = resolvedCode
        let waiters = exitWaiters
        exitWaiters = []
        stateLock.unlock()

        for waiter in waiters { waiter.resume() }
        try? sessionStore.end(tabID: tabID, exitCode: resolvedCode)
    }

    /// Conservative shell-quoting: single-quote and escape any embedded single quotes.
    /// Sufficient for paths and argv items we control.
    static func shellQuote(_ raw: String) -> String {
        let escaped = raw.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }
}

extension CodingAgentRunner: LocalProcessDelegate {
    func dataReceived(slice: ArraySlice<UInt8>) {
        stateLock.lock()
        ring.append(Data(slice))
        stateLock.unlock()
    }

    func processTerminated(_: LocalProcess, exitCode code: Int32?) {
        recordExit(code: code)
    }

    func getWindowSize() -> winsize {
        winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    }
}

enum RunnerError: Error, Equatable {
    case waitTimedOut
}
