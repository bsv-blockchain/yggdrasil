import Darwin
import Foundation
import Observation

/// One open session in Phase 3's debug UI. Phase 4+ will replace this with proper
/// `YggdrasilTab` rows driven by the sidebar.
struct OpenSession: Identifiable, Hashable {
    let id: Int64 // tab id
    let displayName: String // e.g. "Claude · feat/foo"
    let cwd: String
    let command: String
    let args: [String]
    /// Extra environment variables from the agent profile (issue #47). Empty
    /// for sessions with no agent behind them, e.g. "Open Shell".
    let env: [String: String]
    /// ssh host the agent runs on; nil for a local agent.
    let host: RemoteHost?

    init(
        id: Int64, displayName: String, cwd: String,
        command: String, args: [String], env: [String: String] = [:],
        host: RemoteHost? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.cwd = cwd
        self.command = command
        self.args = args
        self.env = env
        self.host = host
    }
}

/// Source of truth for the windows's visible session tabs. `+ New Session` appends;
/// closing a tab removes. Selection drives which `AgentTerminalSurface` is rendered
/// in the main pane.
@Observable
final class SessionsModel {
    var sessions: [OpenSession] = []
    var selectedID: Int64?
    var exitedTabs: [Int64: Int32] = [:]
    /// Remote tabs whose ssh connection dropped and are waiting to reattach.
    private(set) var reconnecting: Set<Int64> = []
    private var reconnectAttempts: [Int64: Int] = [:]

    /// `AgentTerminalSurface.Coordinator` registers its PID here so app-quit
    /// can iterate and SIGTERM every live agent. YggdrasilTab id → PID.
    private var livePIDs: [Int64: pid_t] = [:]

    func add(_ session: OpenSession) {
        // Replace-or-append by id: re-adding the same tab (e.g. Resume Session
        // after an agent exit) swaps the row in place rather than creating a
        // duplicate, so `restartAgent` doesn't depend on `terminate` having
        // already removed the old row.
        if let idx = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[idx] = session
        } else {
            sessions.append(session)
        }
        selectedID = session.id
    }

    func remove(id: Int64) {
        sessions.removeAll { $0.id == id }
        livePIDs[id] = nil
        connectionHeld(tabID: id)
        if selectedID == id {
            selectedID = sessions.first?.id
        }
    }

    func markExited(tabID: Int64, exitCode: Int32) {
        exitedTabs[tabID] = exitCode
    }

    func clearExited(tabID: Int64) {
        exitedTabs.removeValue(forKey: tabID)
    }

    /// Records a dropped connection and returns how many reconnects already
    /// failed in a row, for the backoff.
    func beginReconnect(tabID: Int64) -> Int {
        let attempt = reconnectAttempts[tabID, default: 0]
        reconnectAttempts[tabID] = attempt + 1
        reconnecting.insert(tabID)
        return attempt
    }

    /// The connection stayed up long enough to count as recovered.
    func connectionHeld(tabID: Int64) {
        reconnectAttempts[tabID] = nil
        reconnecting.remove(tabID)
    }

    /// Remounts the tab's terminal so it spawns a fresh `ssh … ygg attach`.
    /// Same two-step as `SidebarActions.restartAgent`: drop the row so SwiftUI
    /// dismantles the dead surface, re-add it on the next runloop tick.
    @MainActor
    func reattach(tabID: Int64) {
        guard let index = sessions.firstIndex(where: { $0.id == tabID }) else { return }
        let session = sessions.remove(at: index)
        livePIDs[tabID] = nil
        DispatchQueue.main.async { [weak self] in
            guard let self, !sessions.contains(where: { $0.id == tabID }) else { return }
            sessions.insert(session, at: min(index, sessions.count))
            // Attempts stay counted until the new connection holds.
            reconnecting.remove(tabID)
        }
    }

    func registerLivePID(_ pid: pid_t, for tabID: Int64) {
        livePIDs[tabID] = pid
    }

    /// Unregisters `pid` if it's still the tab's live process. False when the
    /// tab was terminated, removed or respawned since: its exit was expected.
    func releaseLivePID(_ pid: pid_t, for tabID: Int64) -> Bool {
        guard livePIDs[tabID] == pid else { return false }
        livePIDs[tabID] = nil
        return true
    }

    func livePID(for tabID: Int64) -> pid_t? {
        livePIDs[tabID]
    }

    func unregisterLivePID(for tabID: Int64) {
        livePIDs[tabID] = nil
    }

    /// Returns the snapshot of live agent PIDs at call time. Used by
    /// `AppDelegate.applicationWillTerminate` to SIGTERM every running agent
    /// before the app's own process exits.
    func snapshotLivePIDs() -> [pid_t] {
        Array(livePIDs.values)
    }

    /// Kill the agent for a single tab. SIGTERMs the recorded PID and
    /// drops the OpenSession entry so the sidebar refreshes immediately.
    /// The caller is responsible for any further UI updates (e.g. tab
    /// status repoll). For a remote tab the PID is the local ssh, so this
    /// only detaches; stopping the agent itself is `RemoteSessionControl.kill`.
    @MainActor
    func terminate(tabID: Int64) {
        if let pid = livePIDs[tabID], pid > 0 {
            kill(pid, SIGTERM)
        }
        remove(id: tabID)
    }
}
