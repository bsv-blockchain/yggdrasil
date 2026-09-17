import Foundation
import XCTest
@testable import Yggdrasil

/// Which agent a task picker opens a session with. Before the chooser existed
/// this was hardcoded to the default agent, so a review session could never run
/// on anything but the default — the branch it builds is `<agent>-review-pr-N`
/// and there was no way to make that anything else.
final class AgentChooserTests: XCTestCase {
    private func agent(id: Int64, name: String, command: String, isDefault: Bool = false) -> CodingAgent {
        CodingAgent(
            id: id, name: name, command: command, args: [], env: [:],
            isDefault: isDefault, position: Int(id),
            createdAt: Date(), updatedAt: Date()
        )
    }

    private var claude: CodingAgent {
        agent(id: 1, name: "Claude", command: "claude", isDefault: true)
    }

    private var codex: CodingAgent {
        agent(id: 2, name: "Codex", command: "codex")
    }

    func testExplicitSelectionWins() {
        let resolved = AgentChooser.resolveAgent(
            selectedID: 2, agents: [claude, codex], defaultAgent: claude
        )
        XCTAssertEqual(resolved?.id, 2)
        XCTAssertEqual(resolved?.name, "Codex")
    }

    /// The fast path: open the window, click a row, get what you always got.
    func testNoSelectionFallsBackToDefault() {
        let resolved = AgentChooser.resolveAgent(
            selectedID: nil, agents: [claude, codex], defaultAgent: claude
        )
        XCTAssertEqual(resolved?.id, 1)
    }

    /// A stale selection (agent removed in Preferences while the window was
    /// open) must not resolve to nothing and strand the user.
    func testSelectionOfARemovedAgentFallsBackToDefault() {
        let resolved = AgentChooser.resolveAgent(
            selectedID: 99, agents: [claude, codex], defaultAgent: claude
        )
        XCTAssertEqual(resolved?.id, 1)
    }

    func testNoDefaultFallsBackToFirstConfigured() {
        let resolved = AgentChooser.resolveAgent(
            selectedID: nil, agents: [codex, claude], defaultAgent: nil
        )
        XCTAssertEqual(resolved?.id, codex.id)
    }

    func testNoAgentsResolvesToNil() {
        XCTAssertNil(
            AgentChooser.resolveAgent(selectedID: nil, agents: [], defaultAgent: nil)
        )
    }
}
