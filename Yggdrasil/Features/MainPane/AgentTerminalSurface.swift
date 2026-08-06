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
    /// True when this surface belongs to the currently-selected tab.
    /// Drives auto-focus of the terminal on activation so a tab switch
    /// goes straight from sidebar click → typing into the agent.
    let isActive: Bool
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("yggdrasil.terminalTheme") private var terminalThemeRaw = "auto"

    private var effectiveScheme: ColorScheme {
        switch terminalThemeRaw {
        case "light": .light
        case "dark": .dark
        default: colorScheme
        }
    }

    init(
        tabID: Int64,
        cwd: String,
        command: String,
        args: [String],
        sessionStore: SessionStateStore,
        sessions: SessionsModel? = nil,
        isActive: Bool = false
    ) {
        self.tabID = tabID
        self.cwd = cwd
        self.command = command
        self.args = args
        self.sessionStore = sessionStore
        self.sessions = sessions
        self.isActive = isActive
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tabID: tabID, cwd: cwd, command: command, args: args,
            sessionStore: sessionStore, sessions: sessions
        )
    }

    /// Standard cell font for all agent terminals. Set at construction time
    /// (not via the `font` setter after the fact) so SwiftTerm computes its
    /// cell metrics off the correct font from the start — setting `font`
    /// after creation has been observed to leave the cell grid mis-sized,
    /// which is what makes claude render as if the pane were larger than
    /// it actually is.
    static let cellFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = DroppableTerminalView(frame: .zero)
        AgentTerminalSurface.applyTheme(to: view, scheme: effectiveScheme)
        // Initial state: mouse reporting off (no agent is reading the mouse at
        // launch). `TerminalMouseInterceptor` (mouse events) and
        // `DroppableTerminalView.dataReceived`/`.linefeed` (output) then keep
        // this in sync with the live `mouseMode`:
        //  - OFF when the agent isn't reading the mouse → SwiftTerm keeps the
        //    native text selection alive across streaming output (it clears the
        //    selection on each line feed while reporting is on).
        //  - ON when the agent is reading the mouse (e.g. Claude Code's
        //    fullscreen renderer) → clicks/drags are forwarded so click-to-
        //    expand and the agent's own in-app selection work. There's no
        //    native selection to lose in that mode — the agent owns the mouse.
        view.allowMouseReporting = false
        view.processDelegate = context.coordinator
        context.coordinator.attach(view: view, scheme: effectiveScheme)
        return view
    }

    static func applyTheme(to view: LocalProcessTerminalView, scheme: ColorScheme) {
        view.font = cellFont
        applyColors(to: view, scheme: scheme)
    }

    static func applyColors(to view: LocalProcessTerminalView, scheme: ColorScheme) {
        if scheme == .dark {
            view.nativeBackgroundColor = NSColor(red: 13.0 / 255, green: 14.0 / 255, blue: 17.0 / 255, alpha: 1)
            view.nativeForegroundColor = NSColor(red: 232.0 / 255, green: 234.0 / 255, blue: 239.0 / 255, alpha: 1)
            view.selectedTextBackgroundColor = NSColor(white: 1, alpha: 0.18)
            view.installColors(darkPalette)
        } else {
            view.nativeBackgroundColor = NSColor(red: 251.0 / 255, green: 248.0 / 255, blue: 242.0 / 255, alpha: 1)
            view.nativeForegroundColor = NSColor(red: 26.0 / 255, green: 24.0 / 255, blue: 20.0 / 255, alpha: 1)
            view.selectedTextBackgroundColor = NSColor(white: 0, alpha: 0.12)
            view.installColors(lightPalette)
        }
        view.caretColor = NSColor(red: 70.0 / 255, green: 112.0 / 255, blue: 255.0 / 255, alpha: 1)
        view.useBrightColors = true
    }

    private static func palette(from rgb: [UInt32]) -> [SwiftTerm.Color] {
        rgb.map { hex in
            let red = UInt16((hex >> 16) & 0xFF) &* 0x101
            let green = UInt16((hex >> 8) & 0xFF) &* 0x101
            let blue = UInt16(hex & 0xFF) &* 0x101
            return SwiftTerm.Color(red: red, green: green, blue: blue)
        }
    }

    static let darkPalette: [SwiftTerm.Color] = palette(from: [
        0x0D0E11, 0xFF7B72, 0x7EE787, 0xD29922,
        0x58A6FF, 0xBC8CFF, 0x39C5CF, 0xB1BAC4,
        0x6E7681, 0xFFA198, 0x56D364, 0xE3B341,
        0x79C0FF, 0xD2A8FF, 0x56D4DD, 0xF0F6FC
    ])

    static let lightPalette: [SwiftTerm.Color] = palette(from: [
        0x24292F, 0xCF222E, 0x116329, 0x9A6700,
        0x0550AE, 0x8250DF, 0x1B7C83, 0x6E7781,
        0x57606A, 0xA40E26, 0x1A7F37, 0xBF8700,
        0x0969DA, 0x6639BA, 0x3192AA, 0x8C959F
    ])

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.updateSchemeIfNeeded(effectiveScheme, on: view)
        context.coordinator.setActive(isActive, on: view)
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
        /// Tracked across `setActive` calls so we only steal keyboard
        /// focus on a false→true transition. Nil before the first call.
        private var lastActive: Bool?
        private var lastScheme: ColorScheme?
        private var initialScheme: ColorScheme = .dark

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

        /// Called from `updateNSView` on every layout pass with the
        /// owning tab's selected-state. On a false→true transition (and
        /// on the very first activation) we make the terminal view the
        /// window's first responder so the user can type immediately.
        @MainActor
        func setActive(_ active: Bool, on view: LocalProcessTerminalView) {
            defer { lastActive = active }
            guard active, lastActive != true else { return }
            // Defer one runloop tick so SwiftUI/AppKit has finished any
            // pending layout — without this the makeFirstResponder call
            // can land on a view whose window is still nil.
            DispatchQueue.main.async { [weak view] in
                guard let view, let window = view.window else { return }
                window.makeFirstResponder(view)
            }
        }

        @MainActor
        func updateSchemeIfNeeded(_ scheme: ColorScheme, on view: LocalProcessTerminalView) {
            guard scheme != lastScheme else { return }
            lastScheme = scheme
            AgentTerminalSurface.applyColors(to: view, scheme: scheme)
        }

        func attach(view: LocalProcessTerminalView, scheme: ColorScheme) {
            attachedView = view
            initialScheme = scheme
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
                YggdrasilLog.pty
                    .error("Failed to write session_state.start: \(String(describing: error), privacy: .public)")
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
            let colorfgbg = initialScheme == .light ? "0;15" : "15;0"
            let payload = "export COLORFGBG='\(colorfgbg)'; exec \(quotedCmd) \(quotedArgs)"
            view.startProcess(
                executable: userShell,
                args: ["-l", "-i", "-c", payload],
                environment: nil,
                execName: nil,
                currentDirectory: cwd
            )
            pid = view.process.shellPid
            sessions?.registerLivePID(pid, for: tabID)
            YggdrasilLog.pty
                .info("Spawned agent pid=\(self.pid, privacy: .public) command=\(self.command, privacy: .public)")
        }

        func terminate() {
            // Direct SIGTERM the agent PID; SIGKILL after 5s if it hasn't
            // exited cleanly. Replaces the tmux-killSession path we used
            // when agent survival was a feature.
            let targetPid = pid
            guard targetPid > 0 else { return }
            kill(targetPid, SIGTERM)
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
                YggdrasilLog.pty
                    .error("Failed to write session_state.end: \(String(describing: error), privacy: .public)")
            }
            sessions?.unregisterLivePID(for: tabID)
            let id = tabID
            DispatchQueue.main.async { [weak self] in
                self?.sessions?.markExited(tabID: id, exitCode: resolved)
            }
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
