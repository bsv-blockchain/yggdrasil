import Darwin
import Foundation
import Observation

/// One open session in Phase 3's debug UI. Phase 4+ will replace this with proper
/// `YggdrasilTab` rows driven by the sidebar.
struct OpenSession: Identifiable, Hashable {
    let id: Int64                // tab id
    let displayName: String      // e.g. "Claude · feat/foo"
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

    /// `AgentTerminalSurface.Coordinator` registers its PID here so app-quit
    /// can iterate and SIGTERM every live agent. YggdrasilTab id → PID.
    private var livePIDs: [Int64: pid_t] = [:]

    func add(_ session: OpenSession) {
        sessions.append(session)
        selectedID = session.id
    }

    func remove(id: Int64) {
        sessions.removeAll { $0.id == id }
        livePIDs[id] = nil
        if selectedID == id {
            selectedID = sessions.first?.id
        }
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
