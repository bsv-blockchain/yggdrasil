import AppKit
import SwiftTerm
import XCTest
@testable import Yggdrasil

/// Records what reaches the process delegate, so the forwarding half of
/// `ClipboardReadDenyingDelegate` can be checked: interposing on
/// `terminalDelegate` must not silently swallow the other callbacks (most of
/// them have no-op defaults in `TerminalViewDelegate`, so a missing forward
/// would compile and quietly break the app).
private final class ProcessDelegateSpy: LocalProcessTerminalViewDelegate {
    var title: String?
    var size: (cols: Int, rows: Int)?

    func sizeChanged(source _: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        size = (newCols, newRows)
    }

    func setTerminalTitle(source _: LocalProcessTerminalView, title: String) {
        self.title = title
    }

    func hostCurrentDirectoryUpdate(source _: TerminalView, directory _: String?) {}

    func processTerminated(source _: TerminalView, exitCode _: Int32?) {}
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
            view.terminalDelegate is ClipboardReadDenyingDelegate,
            "without the interposition LocalProcessTerminalView answers OSC 52 reads itself"
        )
    }

    func testClipboardReadIsRefused() {
        let view = makeView()
        XCTAssertNil(view.terminalDelegate?.clipboardRead(source: view))
    }

    func testOtherCallbacksStillReachTheProcessDelegate() {
        let view = makeView()
        let spy = ProcessDelegateSpy()
        view.processDelegate = spy

        view.terminalDelegate?.setTerminalTitle(source: view, title: "yggdrasil")
        view.terminalDelegate?.sizeChanged(source: view, newCols: 120, newRows: 40)

        XCTAssertEqual(spy.title, "yggdrasil")
        XCTAssertEqual(spy.size?.cols, 120)
        XCTAssertEqual(spy.size?.rows, 40)
    }
}
