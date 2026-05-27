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
        view.processDelegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

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
            do {
                _ = try sessionStore.start(tabID: tabID, cwd: cwd, command: command, args: args)
            } catch {
                YggdrasilLog.pty.error("Failed to write session_state.start: \(String(describing: error), privacy: .public)")
            }
            // LocalProcessTerminalView.startProcess accepts currentDirectory: directly,
            // so we don't need the `/bin/sh -c 'cd && exec ...'` wrap that the headless
            // CodingAgentRunner uses (LocalProcess alone doesn't expose a cwd param).
            view.startProcess(
                executable: command,
                args: args,
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

    /// Same `/bin/sh -c 'cd "<cwd>" && exec <cmd> <args>...'` invocation as
    /// `CodingAgentRunner` uses. Exposed `static` so both call sites stay in sync.
    static func cdExecWrap(cwd: String, command: String, args: [String]) -> String {
        let qCwd = CodingAgentRunner.shellQuote(cwd)
        let qCmd = CodingAgentRunner.shellQuote(command)
        let qArgs = args.map(CodingAgentRunner.shellQuote).joined(separator: " ")
        return "cd \(qCwd) && exec \(qCmd) \(qArgs)"
    }
}
