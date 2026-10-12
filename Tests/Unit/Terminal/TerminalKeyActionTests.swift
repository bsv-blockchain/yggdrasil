import AppKit
import XCTest
@testable import Yggdrasil

/// The pure decision behind the terminal key interceptor. Kept free of NSEvent
/// so every branch is testable without a GUI.
///
/// Three keystrokes are intercepted, each because AppKit or SwiftTerm gets it
/// wrong on its own:
/// - Shift+Return — SwiftTerm sends a bare CR, which agents read as "submit".
/// - Option+Up/Down — context-sensitive: the focused terminal gets the escape
///   sequence a CLI expects, anything else steps the sidebar selection.
/// - Cmd+Shift+[ / ] — steps the sidebar selection wherever focus is. Matched
///   by the key the layout prints `[` / `]` on, or by US key position when the
///   layout has no such key, because a menu binding reads "{" once Shift is held.
@MainActor
final class TerminalKeyActionTests: XCTestCase {
    private let returnKey: UInt16 = 36
    private let upKey: UInt16 = 126
    private let downKey: UInt16 = 125
    private let leftBracketKey: UInt16 = 33
    private let rightBracketKey: UInt16 = 30

    /// Arrow keys always carry .function and .numericPad on top of whatever the
    /// user held. Every case here includes them, because the real events do and
    /// a decision that ignores them is the bug this fixes.
    private let arrowNoise: NSEvent.ModifierFlags = [.function, .numericPad]

    private func action(
        _ keyCode: UInt16,
        _ modifiers: NSEvent.ModifierFlags,
        character: String? = nil,
        layoutTypesBrackets: Bool = true,
        terminalFocused: Bool = true,
        mainWindow: Bool = true
    ) -> TerminalKeyAction {
        // Default to what a US layout prints on the key.
        let usCharacter = [leftBracketKey: "[", rightBracketKey: "]"][keyCode]
        return TerminalKeyInterceptor.action(
            keyCode: keyCode, modifiers: modifiers,
            unmodifiedCharacter: character ?? usCharacter,
            layoutTypesBrackets: layoutTypesBrackets,
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

    // MARK: - Cmd+Shift+[ / ]

    /// The whole point: a focused terminal must not swallow it, or the shortcut
    /// is dead for the place the user almost always is.
    func testCmdShiftLeftBracketInTerminalStepsToPreviousSession() {
        XCTAssertEqual(action(leftBracketKey, [.command, .shift]), .previousSession)
    }

    func testCmdShiftRightBracketInTerminalStepsToNextSession() {
        XCTAssertEqual(action(rightBracketKey, [.command, .shift]), .nextSession)
    }

    func testCmdShiftBracketOutsideTerminalStepsSession() {
        XCTAssertEqual(action(leftBracketKey, [.command, .shift], terminalFocused: false), .previousSession)
        XCTAssertEqual(action(rightBracketKey, [.command, .shift], terminalFocused: false), .nextSession)
    }

    func testCmdShiftBracketOutsideMainWindowIsLeftAlone() {
        XCTAssertEqual(
            action(leftBracketKey, [.command, .shift], terminalFocused: false, mainWindow: false),
            .passThrough
        )
    }

    /// Caps Lock isn't a modifier the user means; it must not disarm the shortcut.
    func testCmdShiftBracketWithCapsLockStillSteps() {
        XCTAssertEqual(action(rightBracketKey, [.command, .shift, .capsLock]), .nextSession)
    }

    /// ⌘[ / ⌘] and ⌘⌥⇧[ belong to whoever else binds them.
    func testBracketWithOtherModifiersIsLeftAlone() {
        XCTAssertEqual(action(leftBracketKey, [.command]), .passThrough)
        XCTAssertEqual(action(rightBracketKey, [.command]), .passThrough)
        XCTAssertEqual(action(leftBracketKey, [.command, .shift, .option]), .passThrough)
        XCTAssertEqual(action(leftBracketKey, [.shift]), .passThrough)
    }

    // MARK: - Cmd+Shift+[ / ] on other layouts

    /// Dvorak prints "/" and "=" on the US bracket positions. Taking them would
    /// eat ⌘? (Help search) and ⌘⇧= (zoom).
    func testDvorakUSBracketPositionsAreLeftAlone() {
        XCTAssertEqual(action(leftBracketKey, [.command, .shift], character: "/"), .passThrough)
        XCTAssertEqual(action(rightBracketKey, [.command, .shift], character: "="), .passThrough)
    }

    /// Dvorak's own bracket keys are elsewhere (keycodes 27 / 24); those step,
    /// so the menu label is true.
    func testDvorakBracketKeysStepSession() {
        XCTAssertEqual(action(27, [.command, .shift], character: "["), .previousSession)
        XCTAssertEqual(action(24, [.command, .shift], character: "]"), .nextSession)
    }

    /// Icelandic needs Option to type a bracket, so no key prints one. Fall
    /// back to the US position: ⌘⇧ð / ⌘⇧'.
    func testLayoutWithoutBracketKeysFallsBackToUSPosition() {
        XCTAssertEqual(
            action(leftBracketKey, [.command, .shift], character: "ð", layoutTypesBrackets: false),
            .previousSession
        )
        XCTAssertEqual(
            action(rightBracketKey, [.command, .shift], character: "'", layoutTypesBrackets: false),
            .nextSession
        )
    }

    func testFallbackOnlyAppliesToUSBracketPositions() {
        XCTAssertEqual(
            action(27, [.command, .shift], character: "+", layoutTypesBrackets: false),
            .passThrough
        )
    }

    // MARK: - Everything else

    func testUnrelatedKeyIsLeftAlone() {
        XCTAssertEqual(action(0, [.option]), .passThrough)
    }
}
