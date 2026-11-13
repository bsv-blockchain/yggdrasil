import XCTest
@testable import Yggdrasil

/// How a tab's running subagents are laid out under its sidebar row.
final class SubagentTreeRowsTests: XCTestCase {
    private func info(_ id: String, depth: Int = 1, workflow: SubagentWorkflow? = nil) -> SubagentInfo {
        SubagentInfo(
            agentID: id, agentType: "t", description: id, spawnDepth: depth, background: false,
            lastWrite: nil, transcriptPath: id, workflow: workflow
        )
    }

    func testPlainSubagentsFirstThenEachWorkflowWithItsAgents() {
        let review = SubagentWorkflow(runID: "wf_1", name: "review")
        let rows = SubagentTreeRows.rows([
            info("wf_1:a", workflow: review), info("plain"), info("wf_1:b", workflow: review), info("nested", depth: 2)
        ])
        XCTAssertEqual(rows, [
            .agent(info("plain"), indent: 0),
            .agent(info("nested", depth: 2), indent: 1),
            .workflow(review, agents: 2),
            .agent(info("wf_1:a", workflow: review), indent: 1),
            .agent(info("wf_1:b", workflow: review), indent: 1)
        ])
    }

    func testIDsTheHelperAccepts() {
        XCTAssertTrue(SubagentID.isValid("a1b2"))
        XCTAssertTrue(SubagentID.isValid("wf_0208303c-f4b:a0a039"))
        XCTAssertFalse(SubagentID.isValid(""))
        XCTAssertFalse(SubagentID.isValid("../x"))
        XCTAssertFalse(SubagentID.isValid("../x:a1"))
        XCTAssertFalse(SubagentID.isValid("wf_1:"))
        XCTAssertFalse(SubagentID.isValid(":a1"))
    }
}
