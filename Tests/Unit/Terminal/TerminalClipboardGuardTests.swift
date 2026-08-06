import AppKit
import SwiftTerm
import XCTest
@testable import Yggdrasil

/// Records what reaches the process delegate, so the forwarding half of
/// `ClipboardGuardDelegate` can be checked: interposing on
/// `terminalDelegate` must not silently swallow the other callbacks (most of
/// them have no-op defaults in `TerminalViewDelegate`, so a missing forward
/// would compile and quietly break the app).
private final class ProcessDelegateSpy: LocalProcessTerminalViewDelegate {
    var title: String?
    var directory: String?

    func sizeChanged(source _: LocalProcessTerminalView, newCols _: Int, newRows _: Int) {}

    func setTerminalTitle(source _: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory: String?) {
        self.directory = directory
    }

    func processTerminated(source _: TerminalView, exitCode _: Int32?) {}
}

/// Captures what the emulator writes back towards the PTY without needing a
/// live process: `send(source:data:)` is the `Terminal` → view hop every
/// response takes (`MacTerminalView.swift:845`, and it's `open`). It doesn't
/// call `super`, so no response escapes the test.
private final class RecordingTerminalView: DroppableTerminalView {
    var responses: [UInt8] = []

    override func send(source _: Terminal, data: ArraySlice<UInt8>) {
        responses.append(contentsOf: data)
    }
}

/// OSC 52 clipboard *reads* must never reach the agent. SwiftTerm 1.15.0
/// answers `ESC ] 52 ; c ; ? BEL` from its delegate, and
/// `LocalProcessTerminalView`'s own implementation answers it with the real
/// `NSPasteboard.general` — so output an agent prints could otherwise echo the
/// user's clipboard back into its own stdin.
@MainActor
final class TerminalClipboardGuardTests: XCTestCase {
    private func makeView() -> DroppableTerminalView {
        DroppableTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
    }

    func testViewInterposesOnTerminalDelegate() {
        let view = makeView()
        XCTAssertTrue(
            view.terminalDelegate is ClipboardGuardDelegate,
            "without the interposition LocalProcessTerminalView answers OSC 52 reads itself"
        )
    }

    func testClipboardReadIsRefused() {
        let view = makeView()
        XCTAssertNil(view.terminalDelegate?.clipboardRead(source: view))
    }

    /// The end-to-end version: drive a real `ESC ] 52 ; c ; ? BEL` through the
    /// emulator and assert nothing comes back. Asking the guard directly only
    /// proves it says no — this proves SwiftTerm asks *it*, so the test still
    /// fails if a future version stops routing the query through
    /// `terminalDelegate`. The DA1 case is the control: it shares the same
    /// response path, so a silent OSC 52 can't be mistaken for a dead pipe.
    func testOSC52QueryGetsNoResponseWhileDA1Does() {
        let view = RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))

        view.feed(text: "\u{1b}]52;c;?\u{07}")
        XCTAssertTrue(
            view.responses.isEmpty,
            "OSC 52 read answered with: \(String(bytes: view.responses, encoding: .utf8) ?? "<non-utf8>")"
        )

        view.feed(text: "\u{1b}[c")
        XCTAssertFalse(view.responses.isEmpty, "control query produced no response either")
    }

    /// OSC 52 writes must not reach `NSPasteboard.general` — an agent printing
    /// bytes should never replace what the user copied. Asserted against the
    /// real pasteboard because `clipboardCopy(source: Terminal, content:)` is
    /// `public`, not `open`, so a test subclass can't intercept it; the guard
    /// dropping the write is the only thing standing between the sequence and
    /// `NSPasteboard.general`. Nothing here writes to the pasteboard, so a
    /// passing run leaves the user's clipboard untouched.
    func testOSC52WriteDoesNotReachTheSystemPasteboard() {
        let view = RecordingTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        // base64("pwned-by-osc52") — the payload half of the same OSC.
        view.feed(text: "\u{1b}]52;c;cHduZWQtYnktb3NjNTI=\u{07}")
        XCTAssertNotEqual(
            NSPasteboard.general.string(forType: .string),
            "pwned-by-osc52",
            "OSC 52 write reached the system pasteboard"
        )
    }

    /// Only callbacks that don't depend on a live PTY are asserted here:
    /// `LocalProcessTerminalView.sizeChanged` starts with `guard process.running`
    /// and `send` writes to the child fd, so neither reaches the process
    /// delegate in a unit test. Title and cwd forward unconditionally, which is
    /// enough to prove the interposition didn't swallow the chain.
    func testOtherCallbacksStillReachTheProcessDelegate() {
        let view = makeView()
        let spy = ProcessDelegateSpy()
        view.processDelegate = spy

        view.terminalDelegate?.setTerminalTitle(source: view, title: "yggdrasil")
        view.terminalDelegate?.hostCurrentDirectoryUpdate(source: view, directory: "/tmp/ygg")

        XCTAssertEqual(spy.title, "yggdrasil")
        XCTAssertEqual(spy.directory, "/tmp/ygg")
    }
}
