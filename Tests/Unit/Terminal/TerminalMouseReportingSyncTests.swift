import AppKit
import SwiftTerm
import XCTest
@testable import Yggdrasil

/// `allowMouseReporting` decides whether streaming output clears the user's
/// native text selection, and SwiftTerm reads it in *two* places:
/// `AppleTerminalView.feedPrepare()`, which runs at the top of every `feed`
/// before a single byte is parsed, and `linefeed(source:)`, which runs per line
/// feed while parsing. Syncing the flag only from `linefeed` therefore leaves it
/// stale for a whole chunk whenever the agent changes mouse mode without
/// emitting a line feed — and the next chunk's `feedPrepare` acts on the stale
/// value.
@MainActor
final class TerminalMouseReportingSyncTests: XCTestCase {
    private func makeView() -> DroppableTerminalView {
        DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    /// Output reaches the view through `dataReceived`, which is the path the PTY
    /// uses and the one the sync has to hook — not `feed`, which is `public`
    /// rather than `open` and so can't be overridden.
    private func feed(_ text: String, to view: DroppableTerminalView) {
        view.dataReceived(slice: ArraySlice(Array(text.utf8)))
    }

    func testModeChangeWithoutLinefeedStillSyncsTheFlag() {
        let view = makeView()
        view.allowMouseReporting = false

        feed("\u{1b}[?1003h", to: view)
        XCTAssertTrue(view.allowMouseReporting, "agent asked for hover reporting, no line feed in the chunk")

        feed("\u{1b}[?1003l", to: view)
        XCTAssertFalse(view.allowMouseReporting, "agent left fullscreen, no line feed in the chunk")
    }

    /// Why the flag matters: left stale-true after the agent leaves fullscreen,
    /// the next chunk's `feedPrepare` wipes a selection the user made while no
    /// agent was reading the mouse — the exact case the flag exists to protect.
    func testSelectionSurvivesOutputAfterAgentLeavesMouseMode() {
        let view = makeView()
        feed("\u{1b}[?1003h\r\nhello\r\n", to: view)
        feed("\u{1b}[?1003l", to: view)

        view.selectAll()
        XCTAssertTrue(view.selectionActive, "precondition: something is selected")

        feed("more output", to: view)
        XCTAssertTrue(
            view.selectionActive,
            "reporting is off, so streaming output must leave the native selection alone"
        )
    }

    /// The complementary direction still has to work: while the agent *is*
    /// reading the mouse, output keeps clearing the selection (SwiftTerm's own
    /// behaviour, which the flag must not suppress).
    func testSelectionIsClearedByOutputWhileAgentReadsTheMouse() {
        let view = makeView()
        feed("\u{1b}[?1003h", to: view)

        view.selectAll()
        XCTAssertTrue(view.selectionActive, "precondition: something is selected")

        feed("more output", to: view)
        XCTAssertFalse(view.selectionActive, "reporting is on — SwiftTerm clears the selection as it streams")
    }
}
