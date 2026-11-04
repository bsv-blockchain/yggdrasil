import AppKit
import SwiftTerm
import XCTest
@testable import Yggdrasil

/// Typing into a tab's agent and reading its screen from outside the app.
@MainActor
final class TerminalControlTests: XCTestCase {
    func testTextIsPastedWhenTheAgentAsksForBracketedPaste() {
        XCTAssertEqual(
            TerminalControl.input("a\nb", bracketedPaste: true),
            EscapeSequences.bracketedPasteStart + Array("a\nb".utf8) + EscapeSequences.bracketedPasteEnd,
            "a newline inside a paste stays text instead of submitting"
        )
        XCTAssertEqual(TerminalControl.input("ab", bracketedPaste: false), Array("ab".utf8))
        XCTAssertEqual(TerminalControl.input("", bracketedPaste: true), [])
    }

    func testTextCantEndThePasteEarly() {
        // ESC[201~ inside the text would turn the rest into live keystrokes.
        let input = TerminalControl.input("a\u{1b}[201~\rrm -rf x\u{1b}[200~", bracketedPaste: true)
        XCTAssertEqual(
            input,
            EscapeSequences.bracketedPasteStart + Array("a[201~\rrm -rf x[200~".utf8) + EscapeSequences
                .bracketedPasteEnd
        )
    }

    func testAMarkerHiddenInsideAnotherCantEndThePaste() {
        // Removing each marker once would leave ESC[201~ behind here.
        let input = TerminalControl.input("a\u{1b}[20\u{1b}[201~1~\rb", bracketedPaste: true)
        let start = EscapeSequences.bracketedPasteStart
        let end = EscapeSequences.bracketedPasteEnd
        XCTAssertEqual(Array(input.prefix(start.count)), start)
        XCTAssertEqual(Array(input.suffix(end.count)), end)
        XCTAssertFalse(input.dropFirst(start.count).dropLast(end.count).contains(0x1B))
    }

    func testKeystrokesKeepEscapeSequences() {
        // paste=false: for menus, where a paste is ignored, and keys like Down.
        XCTAssertEqual(TerminalControl.input("\u{1b}[B2", bracketedPaste: false), [0x1B, 0x5B, 0x42, 0x32])
    }

    func testSubmitIsASeparateCarriageReturn() {
        XCTAssertEqual(TerminalControl.submitKey, [0x0D])
    }

    func testScreenReadsWhatTheAgentDrew() {
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "first\r\nsecond\r\n\u{1b}[?2004h")
        let screen = TerminalControl.screen(of: view, scrollback: 0)
        XCTAssertEqual(screen.lines.count, view.getTerminal().rows)
        XCTAssertEqual(Array(screen.lines.prefix(2)), ["first", "second"])
        XCTAssertEqual(screen.cursorRow, 2)
        XCTAssertFalse(screen.alternateScreen)
        XCTAssertTrue(view.getTerminal().bracketedPasteMode)
    }

    func testCellsNothingDrewReadAsSpaces() {
        // A TUI positions text with cursor moves; the cells it skips were
        // never written and come out of the buffer as NUL.
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.feed(text: "a\u{1b}[1;5Hb")
        let screen = TerminalControl.screen(of: view, scrollback: 0)
        XCTAssertEqual(screen.lines.first, "a   b")
    }

    func testScrollbackComesBeforeTheScreen() {
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let rows = view.getTerminal().rows
        view.feed(text: (0 ..< rows + 3).map { "line \($0)" }.joined(separator: "\r\n"))
        let screen = TerminalControl.screen(of: view, scrollback: 2)
        XCTAssertEqual(screen.scrollback, ["line 1", "line 2"])
        XCTAssertEqual(screen.lines.first, "line 3")
    }
}
