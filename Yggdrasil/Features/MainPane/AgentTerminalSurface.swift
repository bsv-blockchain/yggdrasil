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
    /// Extra environment variables from the agent profile (issue #47).
    let env: [String: String]
    let sessionStore: SessionStateStore
    let sessions: SessionsModel?
    /// ssh host to run on; nil runs the agent on this Mac.
    let host: RemoteHost?
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
        env: [String: String] = [:],
        sessionStore: SessionStateStore,
        sessions: SessionsModel? = nil,
        host: RemoteHost? = nil,
        isActive: Bool = false
    ) {
        self.tabID = tabID
        self.cwd = cwd
        self.command = command
        self.args = args
        self.env = env
        self.sessionStore = sessionStore
        self.sessions = sessions
        self.host = host
        self.isActive = isActive
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            tabID: tabID, cwd: cwd, command: command, args: args, env: env,
            sessionStore: sessionStore, sessions: sessions, host: host
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
        // Local paths mean nothing to an agent on another machine.
        view.sendsLocalFilePaths = host == nil
        AgentTerminalSurface.applyTheme(to: view, scheme: effectiveScheme)
        // Initial state: mouse reporting off (no agent is reading the mouse at
        // launch). `DroppableTerminalView.dataReceived`/`.linefeed` then keep
        // this in sync with the live `mouseMode` as output arrives:
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
        let env: [String: String]
        let sessionStore: SessionStateStore
        let host: RemoteHost?
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
            env: [String: String],
            sessionStore: SessionStateStore, sessions: SessionsModel?, host: RemoteHost?
        ) {
            self.tabID = tabID
            self.cwd = cwd
            self.command = command
            self.args = args
            self.env = env
            self.sessionStore = sessionStore
            self.sessions = sessions
            self.host = host
            super.init()
        }

        /// Called from `updateNSView` on every layout pass with the
        /// owning tab's selected-state. On a false→true transition (and
        /// on the very first activation) we make the terminal view the
        /// window's first responder so the user can type immediately.
        @MainActor
        func setActive(_ active: Bool, on view: LocalProcessTerminalView) {
            defer { lastActive = active }
            (view as? DroppableTerminalView)?.isSelectedTab = active
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
            if let host {
                startRemote(on: host, in: view)
                return
            }
            // Pin Claude to the tab's own conversation id (`--session-id` on
            // first spawn, `--resume` after) so it picks up where it left off.
            // Other agent commands fall through untouched.
            let stored: StoredSession
            do {
                stored = try sessionStore.get(tabID: tabID)
                    .map { $0.claudeSessionID.map(StoredSession.pinned) ?? .unpinned } ?? .noRow
            } catch {
                stored = .unknown
            }
            let plan = AgentTerminalSurface.resolveResume(
                command: command, args: args, cwd: cwd,
                stored: stored, newSessionID: UUID().uuidString.lowercased()
            )
            let resolvedArgs = plan.args
            do {
                _ = try sessionStore.start(
                    tabID: tabID, cwd: cwd, command: command, args: resolvedArgs,
                    claudeSessionID: plan.sessionID
                )
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
            // Profile environment goes through the PTY's envp, not the `-c`
            // payload: shell argv is readable by any local process via `ps`,
            // and these values are typically account tokens. nil keeps
            // SwiftTerm's own defaults for profiles with no overrides.
            let environment = AgentEnvironment.merged(
                defaults: Terminal.getEnvironmentVariables(termName: "xterm-256color"),
                overrides: env
            )
            view.startProcess(
                executable: userShell,
                args: ["-l", "-i", "-c", payload],
                environment: environment,
                execName: nil,
                currentDirectory: cwd
            )
            pid = view.process.shellPid
            sessions?.registerLivePID(pid, for: tabID)
            YggdrasilLog.pty
                .info("Spawned agent pid=\(self.pid, privacy: .public) command=\(self.command, privacy: .public)")
            if !env.isEmpty {
                // Names only — values are tokens.
                YggdrasilLog.pty
                    .info("Agent env overrides: \(self.env.keys.sorted().joined(separator: ", "), privacy: .public)")
            }
        }

        func terminate() {
            // SIGTERM, SIGKILL after 5s, and collect the child: this view (and
            // SwiftTerm's exit watcher with it) is usually being torn down, so
            // nothing else would, and it would stay a zombie.
            ChildReaper.stopInBackground(pid)
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
            let id = tabID
            let exitedPID = pid
            // The child is gone (SwiftTerm collected it); a later terminate()
            // on this surface must not signal its pid, which may be reused.
            pid = 0
            let remote = host != nil
            DispatchQueue.main.async { [weak self] in
                guard let sessions = self?.sessions else { return }
                // Only the tab's current process can have lost its connection;
                // one we terminated or replaced was meant to exit.
                let wasCurrent = sessions.releaseLivePID(exitedPID, for: id)
                if wasCurrent, ReconnectPolicy.shouldReconnect(isRemote: remote, exitCode: exitCode) {
                    let attempt = sessions.beginReconnect(tabID: id)
                    if !ReconnectPolicy.shouldGiveUp(attempt: attempt) {
                        // Possibly just the link: the agent keeps running in
                        // dtach on the host. Reattach with backoff.
                        let delay = ReconnectPolicy.delaySeconds(attempt: attempt)
                        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak sessions] in
                            guard let sessions, sessions.reconnecting.contains(id) else { return }
                            sessions.reattach(tabID: id)
                        }
                        return
                    }
                    sessions.connectionHeld(tabID: id)
                }
                sessions.markExited(tabID: id, exitCode: resolved)
            }
            YggdrasilLog.pty.info("Agent pid=\(exitedPID, privacy: .public) exited code=\(resolved, privacy: .public)")
        }
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

// MARK: - Remote tabs

extension AgentTerminalSurface.Coordinator {
    /// Runs `ssh … ygg attach`, which attaches to the tab's dtach session
    /// on the host or creates it. Killing this process only detaches.
    private func startRemote(on host: RemoteHost, in view: LocalProcessTerminalView) {
        let storedID: String?
        let newID: String?
        do {
            storedID = try sessionStore.get(tabID: tabID)?.claudeSessionID
            newID = UUID().uuidString.lowercased()
        } catch {
            // Unreadable row: don't pin rather than mint over a possible pin.
            storedID = nil
            newID = nil
        }
        let spawn = RemoteSpawn.make(
            host: host,
            session: OpenSession(id: tabID, displayName: "", cwd: cwd, command: command, args: args),
            storedSessionID: storedID,
            newSessionID: newID,
            colorfgbg: initialScheme == .light ? "0;15" : "15;0"
        )
        do {
            _ = try sessionStore.start(
                tabID: tabID, cwd: cwd, command: command, args: args,
                claudeSessionID: spawn.claudeSessionID
            )
        } catch {
            YggdrasilLog.pty
                .error("Failed to write session_state.start: \(String(describing: error), privacy: .public)")
        }
        if !env.isEmpty {
            // Locally these go through the PTY's envp so tokens never show
            // in `ps`; over ssh the only route today is the command line,
            // visible in `ps` on both machines. Not passed until there's a
            // private channel. Names only — values are tokens.
            YggdrasilLog.pty.warning(
                "Agent env vars not passed to remote tab: \(self.env.keys.sorted().joined(separator: ", "), privacy: .public)"
            )
        }
        SSHCommand.prepareControlDirectory()
        view.startProcess(
            executable: spawn.executable,
            args: spawn.args,
            environment: nil,
            execName: nil,
            currentDirectory: NSHomeDirectory()
        )
        pid = view.process.shellPid
        sessions?.registerLivePID(pid, for: tabID)
        // A connection that stays up this long has recovered; reset backoff.
        let id = tabID
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, lastExitCode == nil else { return }
            sessions?.connectionHeld(tabID: id)
        }
        YggdrasilLog.pty.info(
            "Attaching tab \(self.tabID, privacy: .public) on \(host.sshTarget, privacy: .public) pid=\(self.pid, privacy: .public)"
        )
    }
}
