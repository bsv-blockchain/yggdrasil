import Foundation

/// Wraps every agent spawn in a tmux session so the process survives Yggdrasil
/// closing. tmux's daemon owns the agent; Yggdrasil's PTY just runs
/// `tmux attach`. When the app quits, the attach exits but the session stays
/// alive on the daemon. On next launch we attach to the same session and the
/// agent is exactly where it was — same PID, same scrollback, same in-flight
/// tool calls.
///
/// All sessions live on a private tmux socket (`-L yggdrasil`) so we don't
/// touch the user's normal tmux setup.
///
/// `tmux` is treated as an optional dependency: when it's not on `PATH` the
/// app degrades to today's direct-exec spawn (no survival) and logs a warning
/// at launch.
struct TmuxManager: Sendable {
    /// Private tmux socket — isolates Yggdrasil sessions from the user's
    /// regular tmux server. Files land in `$TMPDIR/tmux-<uid>/yggdrasil`.
    static let socketName = "yggdrasil"

    /// Absolute path to the `tmux` binary on this machine, or `nil` if not
    /// installed. Determined at app launch via `which tmux` and stashed for
    /// the lifetime of the process; we don't rescan on every spawn.
    let tmuxPath: String?

    /// `true` when tmux was found at launch and we should route spawns
    /// through `wrapCommand`. `false` falls back to direct `exec <cmd>`.
    var isAvailable: Bool { tmuxPath != nil }

    // MARK: - Naming

    /// Per-tab session name. Stable across launches because tab IDs are
    /// stored in SQLite, so reopening the app finds the same session.
    static func sessionName(forTabID tabID: Int64) -> String {
        "yggdrasil-tab-\(tabID)"
    }

    // MARK: - Construction

    /// Probes PATH for `tmux` once at app start. Looks via the user's login
    /// shell so brew-installed tmux is found even when Yggdrasil was launched
    /// from Finder (which inherits a stripped PATH).
    static func detect() -> TmuxManager {
        TmuxManager(tmuxPath: locateTmux())
    }

    private static func locateTmux() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "command -v tmux"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }

    // MARK: - Wrap script

    /// Build the `sh -c` payload that runs inside Yggdrasil's PTY for a tab.
    ///
    /// Two-step idempotent flow:
    /// 1. `tmux has-session` — true on subsequent launches, false on first.
    /// 2. If false: `new-session -d` with the agent command, then turn the
    ///    session's status bar off (cosmetic — claude renders its own UI).
    /// 3. Either way: `exec tmux attach`.
    ///
    /// The `resumeArgs` are applied (e.g. claude `--continue`) only on the
    /// first-spawn branch — when the session already exists, attaching shows
    /// the agent that's already running and a resume flag would be ignored
    /// anyway.
    func wrapCommand(
        tabID: Int64,
        cwd: String,
        command: String,
        args: [String],
        resumeArgs: [String]
    ) -> String {
        let session = Self.sessionName(forTabID: tabID)
        let qSession = CodingAgentRunner.shellQuote(session)
        let qSocket = CodingAgentRunner.shellQuote(Self.socketName)
        let qCwd = CodingAgentRunner.shellQuote(cwd)
        let qCmd = CodingAgentRunner.shellQuote(command)
        let qArgs = resumeArgs.map(CodingAgentRunner.shellQuote).joined(separator: " ")
        // Build the inner command that tmux runs as the session's first
        // process. `exec` keeps tmux's pane PID == the agent PID so the
        // sidebar's PID-aware status pip stays accurate.
        let inner = "exec \(qCmd) \(qArgs)"
        let qInner = CodingAgentRunner.shellQuote(inner)
        return """
        if ! tmux -L \(qSocket) has-session -t \(qSession) 2>/dev/null; then
          tmux -L \(qSocket) new-session -d -s \(qSession) -c \(qCwd) sh -c \(qInner) && \
          tmux -L \(qSocket) set-option -t \(qSession) status off >/dev/null
        fi
        exec tmux -L \(qSocket) attach -t \(qSession)
        """
    }

    // MARK: - Management commands

    /// True if a session for `tabID` currently exists on the socket. Used by
    /// the menu bar to decide whether to show a row for a tab that no longer
    /// has an attached client.
    func sessionExists(forTabID tabID: Int64) -> Bool {
        guard let tmuxPath else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tmuxPath)
        process.arguments = ["-L", Self.socketName, "has-session", "-t", Self.sessionName(forTabID: tabID)]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// Kill the tmux session for a single tab. No-op if tmux isn't available
    /// or the session is already gone.
    @discardableResult
    func killSession(forTabID tabID: Int64) -> Bool {
        runTmux(args: ["kill-session", "-t", Self.sessionName(forTabID: tabID)])
    }

    /// Kill every Yggdrasil tmux session on the socket. Returns true if all
    /// kills succeeded (or there was nothing to kill).
    @discardableResult
    func killAllSessions() -> Bool {
        guard let tmuxPath else { return true }
        let names = listSessions()
        var ok = true
        for name in names {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: tmuxPath)
            proc.arguments = ["-L", Self.socketName, "kill-session", "-t", name]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            do {
                try proc.run()
                proc.waitUntilExit()
                if proc.terminationStatus != 0 { ok = false }
            } catch {
                ok = false
            }
        }
        return ok
    }

    /// All session names currently on the Yggdrasil socket. Empty when the
    /// daemon isn't running.
    func listSessions() -> [String] {
        guard let tmuxPath else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["-L", Self.socketName, "list-sessions", "-F", "#S"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return []
        }
        // tmux exits 1 with "no server running" when the daemon isn't up;
        // that's not an error to surface, just an empty list.
        guard proc.terminationStatus == 0 else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        return Self.parseSessionList(text)
    }

    /// Pure helper for testability — splits `tmux list-sessions -F '#S'`
    /// output into names, dropping blanks.
    static func parseSessionList(_ output: String) -> [String] {
        output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Internals

    @discardableResult
    private func runTmux(args: [String]) -> Bool {
        guard let tmuxPath else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tmuxPath)
        proc.arguments = ["-L", Self.socketName] + args
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }
}
