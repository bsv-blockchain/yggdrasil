import AppKit
import SwiftTerm
import XCTest
@testable import Yggdrasil

/// OSC 52 *writes* go through only right after the user's own input in that
/// terminal: over ssh there's no pbcopy, so Claude's copy-on-select arrives
/// as OSC 52, while bytes an agent prints on its own still can't replace the
/// clipboard. Writes go to a recorder, never `NSPasteboard.general`.
@MainActor
final class TerminalClipboardWriteTests: XCTestCase {
    private var written: [String] = []

    private func makeView() throws -> DroppableTerminalView {
        let view = DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let guardDelegate = try XCTUnwrap(view.terminalDelegate as? ClipboardGuardDelegate)
        guardDelegate.pasteboardWriter = { [weak self] in self?.written.append($0) }
        view.isSelectedTab = true
        return view
    }

    /// base64("copied text")
    private let osc52Write = "\u{1b}]52;c;Y29waWVkIHRleHQ=\u{07}"

    func testWriteRightAfterUserInputReachesThePasteboard() throws {
        let view = try makeView()
        view.lastUserInputAt = .now - .milliseconds(500)
        view.feed(text: osc52Write)
        XCTAssertEqual(written, ["copied text"])
    }

    func testWriteWithoutAnyUserInputIsRefused() throws {
        let view = try makeView()
        view.feed(text: osc52Write)
        XCTAssertEqual(written, [])
    }

    func testWriteLongAfterUserInputIsRefused() throws {
        let view = try makeView()
        view.lastUserInputAt = .now - .seconds(3)
        view.feed(text: osc52Write)
        XCTAssertEqual(written, [])
    }

    func testReadIsStillRefusedRightAfterUserInput() throws {
        let view = try makeView()
        view.lastUserInputAt = .now
        XCTAssertNil(view.terminalDelegate?.clipboardRead(source: view))
    }

    func testInputInOneTerminalDoesNotOpenAnother() throws {
        let typedInto = try makeView()
        let other = try makeView()
        TerminalInputClock.stamp(firstResponder: typedInto)
        other.feed(text: osc52Write)
        XCTAssertEqual(written, [])
    }

    /// A hidden tab's terminal can keep focus when the newly selected tab has
    /// no terminal to take it; input meant for the visible tab mustn't count.
    func testADeselectedTabIsNeitherStampedNorWritten() throws {
        let view = try makeView()
        view.lastUserInputAt = .now
        view.isSelectedTab = false
        XCTAssertNil(view.lastUserInputAt, "deselecting forgets the last input")

        TerminalInputClock.stamp(firstResponder: view)
        XCTAssertNil(view.lastUserInputAt)

        view.lastUserInputAt = .now
        view.feed(text: osc52Write)
        XCTAssertEqual(written, [])
    }

    func testOnlyTypingAndClicksInsideTheTerminalCount() {
        XCTAssertTrue(TerminalInputClock.shouldStamp(eventType: .keyDown, modifiers: [], isInsideView: true))
        XCTAssertTrue(TerminalInputClock.shouldStamp(eventType: .keyDown, modifiers: .shift, isInsideView: true))
        XCTAssertFalse(
            TerminalInputClock.shouldStamp(eventType: .keyDown, modifiers: .command, isInsideView: true),
            "a ⌘C of the user's own would open the window for an overwrite"
        )
        XCTAssertTrue(TerminalInputClock.shouldStamp(eventType: .leftMouseUp, modifiers: [], isInsideView: true))
        XCTAssertFalse(TerminalInputClock.shouldStamp(eventType: .leftMouseDown, modifiers: [], isInsideView: false))
    }

    func testInputStampsOnlyATerminalThatHasFocus() throws {
        let view = try makeView()
        TerminalInputClock.stamp(firstResponder: NSTextView())
        XCTAssertNil(view.lastUserInputAt)
        TerminalInputClock.stamp(firstResponder: view)
        XCTAssertNotNil(view.lastUserInputAt)
    }
}
