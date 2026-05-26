import Foundation
import Observation

/// One open session in Phase 3's debug UI. Phase 4+ will replace this with proper
/// `Tab` rows driven by the sidebar.
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

    func add(_ session: OpenSession) {
        sessions.append(session)
        selectedID = session.id
    }

    func remove(id: Int64) {
        sessions.removeAll { $0.id == id }
        if selectedID == id {
            selectedID = sessions.first?.id
        }
    }
}
