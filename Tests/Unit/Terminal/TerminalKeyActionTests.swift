import AppKit
import XCTest
@testable import Yggdrasil

/// The pure decision behind the terminal key interceptor. Kept free of NSEvent
/// so every branch is testable without a GUI.
///
/// Two keystrokes are intercepted, both because AppKit or SwiftTerm gets them
/// wrong on its own:
/// - Shift+Return — SwiftTerm sends a bare CR, which agents read as "submit".
/// - Option+Up/Down — context-sensitive: the focused terminal gets the escape
///   sequence a CLI expects, anything else steps the sidebar selection.
@MainActor
final class TerminalKeyActionTests: XCTestCase {
    private let returnKey: UInt16 = 36
    private let upKey: UInt16 = 126
    private let downKey: UInt16 = 125

    /// Arrow keys always carry .function and .numericPad on top of whatever the
    /// user held. Every case here includes them, because the real events do and
    /// a decision that ignores them is the bug this fixes.
    private let arrowNoise: NSEvent.ModifierFlags = [.function, .numericPad]

    private func action(
        _ keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags,
        terminalFocused: Bool = true,
        mainWindow: Bool = true
    ) -> TerminalKeyAction {
        TerminalKeyInterceptor.action(
            keyCode: keyCode, modifiers: modifiers,
            isTerminalFocused: terminalFocused, isMainWindow: mainWindow
        )
    }

    // MARK: - Shift+Return

    func testShiftReturnInTerminalSendsEscapeCR() {
        XCTAssertEqual(action(returnKey, [.shift]), .sendBytes([0x1B, 0x0D]))
    }

    func testShiftReturnOutsideTerminalIsLeftAlone() {
        XCTAssertEqual(action(returnKey, [.shift], terminalFocused: false), .passThrough)
    }

    func testPlainReturnIsLeftAlone() {
        XCTAssertEqual(action(returnKey, []), .passThrough)
    }

    func testShiftReturnWithAnotherModifierIsLeftAlone() {
        XCTAssertEqual(action(returnKey, [.shift, .command]), .passThrough)
    }

    // MARK: - Option+arrows in a terminal

    func testOptionUpInTerminalSendsCSIAltUp() {
        // ESC [ 1 ; 3 A — the xterm encoding for Alt+Up.
        XCTAssertEqual(
            action(upKey, arrowNoise.union(.option)),
            .sendBytes([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x41])
        )
    }

    func testOptionDownInTerminalSendsCSIAltDown() {
        XCTAssertEqual(
            action(downKey, arrowNoise.union(.option)),
            .sendBytes([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x42])
        )
    }

    /// SwiftTerm handles a bare arrow correctly; don't intercept it.
    func testPlainArrowInTerminalIsLeftAlone() {
        XCTAssertEqual(action(upKey, arrowNoise), .passThrough)
    }

    func testOptionArrowWithExtraModifierIsLeftAlone() {
        XCTAssertEqual(action(upKey, arrowNoise.union([.option, .shift])), .passThrough)
    }

    // MARK: - Option+arrows outside a terminal

    func testOptionUpOutsideTerminalStepsToPreviousSession() {
        XCTAssertEqual(
            action(upKey, arrowNoise.union(.option), terminalFocused: false),
            .previousSession
        )
    }

    func testOptionDownOutsideTerminalStepsToNextSession() {
        XCTAssertEqual(
            action(downKey, arrowNoise.union(.option), terminalFocused: false),
            .nextSession
        )
    }

    /// A picker or Preferences window shares the service graph; stepping the
    /// background window's selection there would strand the user on a different
    /// agent's terminal on return.
    func testOptionArrowOutsideMainWindowIsLeftAlone() {
        XCTAssertEqual(
            action(upKey, arrowNoise.union(.option), terminalFocused: false, mainWindow: false),
            .passThrough
        )
    }

    /// Terminals only live in the main window, but the terminal branch is
    /// deliberately independent of the window check.
    func testOptionArrowInTerminalStillSendsBytesOutsideMainWindow() {
        XCTAssertEqual(
            action(upKey, arrowNoise.union(.option), mainWindow: false),
            .sendBytes([0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x41])
        )
    }

    // MARK: - Everything else

    func testUnrelatedKeyIsLeftAlone() {
        XCTAssertEqual(action(0, [.option]), .passThrough)
    }
}
