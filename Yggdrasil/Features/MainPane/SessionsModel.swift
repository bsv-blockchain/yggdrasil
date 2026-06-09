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
}

/// Source of truth for the windows's visible session tabs. `+ New Session` appends;
/// closing a tab removes. Selection drives which `AgentTerminalSurface` is rendered
/// in the main pane.
@Observable
final class SessionsModel {
    var sessions: [OpenSession] = []
    var selectedID: Int64?
    var exitedTabs: [Int64: Int32] = [:]

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

    func registerLivePID(_ pid: pid_t, for tabID: Int64) {
        livePIDs[tabID] = pid
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
    /// status repoll).
    @MainActor
    func terminate(tabID: Int64) {
        if let pid = livePIDs[tabID], pid > 0 {
            kill(pid, SIGTERM)
        }
        remove(id: tabID)
    }
}
