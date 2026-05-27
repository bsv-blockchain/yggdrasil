import AppKit
import Darwin
import Foundation
import SwiftTerm
import SwiftUI

/// SwiftUI wrapper around `SwiftTerm.LocalProcessTerminalView`. One per visible
/// agent tab. Spawns the agent on first appearance, records `session_state`
/// transitions to the injected `SessionStateStore`, and captures the last 4KB
/// of agent output to a shared `OutputRingBuffer` (used by Phase 6).
///
/// Mirrors the `CodingAgentRunner` headless lifecycle but uses
/// `LocalProcessTerminalView` so we get real rendering. Both paths flow through
/// the same `SessionStateStore` and share the `/bin/sh -c 'cd && exec`
/// invocation pattern (no interactive shell).
struct AgentTerminalSurface: NSViewRepresentable {

    let tabID: Int64
    let cwd: String
    let command: String
    let args: [String]
    let sessionStore: SessionStateStore
    let sessions: SessionsModel?

    init(
        tabID: Int64,
        cwd: String,
        command: String,
        args: [String],
        sessionStore: SessionStateStore,
        sessions: SessionsModel? = nil
    ) {
        self.tabID = tabID
        self.cwd = cwd
        self.command = command
        self.args = args
        self.sessionStore = sessionStore
        self.sessions = sessions
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tabID: tabID, cwd: cwd, command: command, args: args,
            sessionStore: sessionStore, sessions: sessions
        )
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        AgentTerminalSurface.applyTheme(to: view)
        view.processDelegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    /// Apply a Terminal.app / Warp-style theme so the embedded PTY matches what
    /// the user is used to in their normal shell:
    /// - SF Mono 13pt (NSFont.monospacedSystemFont) — same as macOS Terminal.app
    ///   and modern Warp/iTerm defaults.
    /// - Dark background, off-white foreground, balanced ANSI 16 palette
    ///   modeled on GitHub's dark theme so syntax-coloured output (claude
    ///   transcripts, git log, etc.) renders close to Warp.
    static func applyTheme(to view: LocalProcessTerminalView) {
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 13.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 232.0 / 255, green: 234.0 / 255, blue: 239.0 / 255, alpha: 1)
        view.caretColor = NSColor(red: 70.0 / 255, green: 112.0 / 255, blue: 255.0 / 255, alpha: 1)
        view.selectedTextBackgroundColor = NSColor(white: 1, alpha: 0.18)
        view.useBrightColors = true
        view.installColors(Self.ansiPalette)
    }

    /// ANSI 16-colour palette (8 normal + 8 bright). GitHub Dark-style — works
    /// well with claude transcripts, git log/diff, and the syntax highlighting
    /// most agent CLIs emit. SwiftTerm's `Color` wants 16-bit channels
    /// (0...65535), so each 8-bit hex byte is multiplied by 0x101.
    private static let ansiPalette: [SwiftTerm.Color] = {
        let rgb: [UInt32] = [
            0x0d0e11, // black
            0xff7b72, // red
            0x7ee787, // green
            0xd29922, // yellow
            0x58a6ff, // blue
            0xbc8cff, // magenta
            0x39c5cf, // cyan
            0xb1bac4, // white
            0x6e7681, // bright black
            0xffa198, // bright red
            0x56d364, // bright green
            0xe3b341, // bright yellow
            0x79c0ff, // bright blue
            0xd2a8ff, // bright magenta
            0x56d4dd, // bright cyan
            0xf0f6fc  // bright white
        ]
        return rgb.map { hex in
            let red = UInt16((hex >> 16) & 0xff) &* 0x101
            let green = UInt16((hex >> 8) & 0xff) &* 0x101
            let blue = UInt16(hex & 0xff) &* 0x101
            return SwiftTerm.Color(red: red, green: green, blue: blue)
        }
    }()

    func updateNSView(_: LocalProcessTerminalView, context _: Context) {
        // Static for now — Phase 4+ will plumb resize/font changes here.
    }

    static func dismantleNSView(_: LocalProcessTerminalView, coordinator: Coordinator) {
        coordinator.terminate()
    }

    /// Owns the lifecycle bookkeeping for one terminal surface — what's currently
    /// running, where its bytes go (ring + session_state), and how to shut it down.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        let tabID: Int64
        let cwd: String
        let command: String
        let args: [String]
        let sessionStore: SessionStateStore
        private weak var sessions: SessionsModel?
        private weak var attachedView: LocalProcessTerminalView?
        private let lock = NSLock()
        private var ring = OutputRingBuffer.makeAgentOutputRing()
        private var lastExitCode: Int32?
        private var didStart = false
        private var pid: pid_t = 0

        init(
            tabID: Int64, cwd: String, command: String, args: [String],
            sessionStore: SessionStateStore, sessions: SessionsModel?
        ) {
            self.tabID = tabID
            self.cwd = cwd
            self.command = command
            self.args = args
            self.sessionStore = sessionStore
            self.sessions = sessions
            super.init()
        }

        func attach(view: LocalProcessTerminalView) {
            attachedView = view
            startIfNeeded(in: view)
        }

        private func startIfNeeded(in view: LocalProcessTerminalView) {
            guard !didStart else { return }
            didStart = true
            // If Claude has prior conversation history for this worktree
            // (transcripts under ~/.claude/projects/<encoded-cwd>/*.jsonl),
            // append `--continue` so the agent picks up where it left off.
            // Other agent commands fall through untouched.
            let resolvedArgs = AgentTerminalSurface.applyResumeFlag(
                command: command, args: args, cwd: cwd
            )
            do {
                _ = try sessionStore.start(tabID: tabID, cwd: cwd, command: command, args: resolvedArgs)
            } catch {
                YggdrasilLog.pty.error("Failed to write session_state.start: \(String(describing: error), privacy: .public)")
            }
            // Spawn through the user's login + interactive shell so .zprofile AND
            // .zshrc both run, picking up PATH edits and `eval $(brew shellenv)`
            // wherever the user keeps them. Apps launched from Finder otherwise
            // see a stripped /usr/bin:/bin PATH and exit immediately with 127
            // ("command not found: claude"). The `-c` plus `exec` keeps the
            // shell out of the agent's signal path while still sourcing the
            // user's rc files.
            let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let quotedCmd = CodingAgentRunner.shellQuote(command)
            let quotedArgs = resolvedArgs.map(CodingAgentRunner.shellQuote).joined(separator: " ")
            view.startProcess(
                executable: userShell,
                args: ["-l", "-i", "-c", "exec \(quotedCmd) \(quotedArgs)"],
                environment: nil,
                execName: nil,
                currentDirectory: cwd
            )
            pid = view.process.shellPid
            sessions?.registerLivePID(pid, for: tabID)
            YggdrasilLog.pty.info("Spawned agent pid=\(self.pid, privacy: .public) command=\(self.command, privacy: .public)")
        }

        func terminate() {
            let targetPid = pid
            guard targetPid > 0 else { return }
            kill(targetPid, SIGTERM)
            // Fallback SIGKILL after 5s (spec §Phase 3 clean-shutdown deliverable).
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                if self?.lastExitCode == nil {
                    kill(targetPid, SIGKILL)
                }
            }
        }

        // MARK: - LocalProcessTerminalViewDelegate

        func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {}

        func setTerminalTitle(source _: LocalProcessTerminalView, title _: String) {}

        func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

        func setup() {}

        func processTerminated(source _: TerminalView, exitCode: Int32?) {
            let resolved = exitCode ?? -1
            lock.lock()
            lastExitCode = resolved
            lock.unlock()
            do {
                try sessionStore.end(tabID: tabID, exitCode: resolved)
            } catch {
                YggdrasilLog.pty.error("Failed to write session_state.end: \(String(describing: error), privacy: .public)")
            }
            sessions?.unregisterLivePID(for: tabID)
            YggdrasilLog.pty.info("Agent pid=\(self.pid, privacy: .public) exited code=\(resolved, privacy: .public)")
        }
    }

    /// Append the agent-specific resume flag to `args` when there's a prior
    /// conversation for this cwd. Currently Claude-aware only: `claude
    /// --continue` resumes the most recent conversation in the cwd, but
    /// errors out (exit 1) when no transcript exists. Checking the
    /// session_state row isn't enough — claude stores its history under
    /// `~/.claude/projects/<encoded-cwd>/*.jsonl`, and that's where we look.
    /// Pure for testability.
    static func applyResumeFlag(
        command: String,
        args: [String],
        cwd: String,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        directoryContents: (String) -> [String]? = {
            try? FileManager.default.contentsOfDirectory(atPath: $0)
        }
    ) -> [String] {
        let lowerCmd = command.lowercased()
        guard lowerCmd.contains("claude") else { return args }
        // Don't double-up if the user already set the flag.
        if args.contains("--continue") || args.contains("-c") || args.contains("--resume") {
            return args
        }
        // claude maps cwd → ~/.claude/projects/<encoded>/ where the encoding
        // replaces every `/` and `.` with a `-`. So
        //   /Users/me/checkout/.worktrees/pr-643
        // becomes
        //   -Users-me-checkout--worktrees-pr-643
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let home = NSHomeDirectory()
        let projectDir = "\(home)/.claude/projects/\(encoded)"
        guard fileExists(projectDir),
              let entries = directoryContents(projectDir),
              entries.contains(where: { $0.hasSuffix(".jsonl") })
        else { return args }
        return args + ["--continue"]
    }

    /// Same `/bin/sh -c 'cd "<cwd>" && exec <cmd> <args>...'` invocation as
    /// `CodingAgentRunner` uses. Exposed `static` so both call sites stay in sync.
    static func cdExecWrap(cwd: String, command: String, args: [String]) -> String {
        let qCwd = CodingAgentRunner.shellQuote(cwd)
        let qCmd = CodingAgentRunner.shellQuote(command)
        let qArgs = args.map(CodingAgentRunner.shellQuote).joined(separator: " ")
        return "cd \(qCwd) && exec \(qCmd) \(qArgs)"
    }
}
