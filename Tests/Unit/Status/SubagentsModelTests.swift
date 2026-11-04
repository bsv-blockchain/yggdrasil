import XCTest
@testable import Yggdrasil

/// What the sidebar shows under a tab, and which subagent's transcript is open.
final class SubagentsModelTests: XCTestCase {
    private let explore = SubagentInfo(
        agentID: "a1", agentType: "Explore", description: "Find tests", spawnDepth: 1, background: true, lastWrite: nil,
        transcriptPath: "/p/agent-a1.jsonl"
    )

    func testOnlyARunningAgentHasRunningSubagents() {
        let model = SubagentsModel()
        model.set([explore], forTabID: 1)
        XCTAssertEqual(model.running(forTabID: 1, parentRunning: true), [explore])
        // Claude was killed: its subagents' meta files still say unfinished.
        XCTAssertEqual(model.running(forTabID: 1, parentRunning: false), [])
        XCTAssertEqual(model.running(forTabID: 2, parentRunning: true), [])
    }

    func testAViewThatSawNoneYetIsToldWhenSomeArrive() {
        // The sidebar first draws before the tab's terminal is up. If that
        // read didn't touch the list, the rows would never appear.
        let model = SubagentsModel()
        let changed = expectation(description: "observed")
        withObservationTracking {
            _ = model.running(forTabID: 1, parentRunning: false)
        } onChange: {
            changed.fulfill()
        }
        model.set([explore], forTabID: 1)
        wait(for: [changed], timeout: 1)
    }

    func testTheOpenTranscriptOutlivesTheRowWhenTheSubagentFinishes() {
        let model = SubagentsModel()
        model.set([explore], forTabID: 1)
        model.select(explore, tabID: 1)
        model.set([], forTabID: 1)
        XCTAssertEqual(model.selection(forTabID: 1)?.info, explore)
        XCTAssertNil(model.selection(forTabID: 2))
        model.clearSelection()
        XCTAssertNil(model.selection(forTabID: 1))
    }

    func testClosedTabsAreForgotten() {
        let model = SubagentsModel()
        model.set([explore], forTabID: 1)
        model.set([explore], forTabID: 2)
        model.select(explore, tabID: 2)
        model.retain(tabIDs: [1])
        XCTAssertEqual(model.running(forTabID: 2, parentRunning: true), [])
        XCTAssertNil(model.selection(forTabID: 2))
        XCTAssertEqual(model.running(forTabID: 1, parentRunning: true), [explore])
    }
}
