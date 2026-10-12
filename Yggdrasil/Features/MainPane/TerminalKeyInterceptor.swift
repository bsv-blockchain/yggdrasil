import AppKit
import SwiftTerm

/// What the interceptor decided to do with a key event.
enum TerminalKeyAction: Equatable {
    /// Not ours — let AppKit and SwiftTerm have it.
    case passThrough
    /// Write these bytes to the focused terminal and swallow the event.
    case sendBytes([UInt8])
    case previousSession
    case nextSession
}

/// Key rewriter for the keystrokes neither AppKit nor SwiftTerm gets right.
///
/// **Shift+Return.** SwiftTerm's default `keyDown` routes Return (with or
/// without Shift) through `interpretKeyEvents`, which on macOS maps to
/// `insertNewline:` and sends a plain CR (`\r`) to the PTY. Claude Code (and
/// most other agents) treat plain CR as "submit"; they look for `ESC + CR`
/// (`\e\r`) — the same encoding iTerm2 emits — to insert a literal newline.
///
/// **Option+Up/Down.** Context-sensitive, and broken on both sides before this:
/// - In a terminal, SwiftTerm handles Option+Left/Right explicitly
///   (`MacTerminalView.keyDown`, the `optionAsMetaKey` branch) but lets Up/Down
///   fall through to `send(cmdEsc)` + `send(txt: rawCharacter)` — ESC followed
///   by the raw `NSUpArrowFunctionKey` glyph (U+F700), which no CLI
///   understands. We send the xterm encoding `ESC [ 1 ; 3 A` / `B` instead.
/// - Outside a terminal it steps the sidebar selection, the job the
///   Previous/Next Session menu items advertise.
///
/// A menu key equivalent can't express "context-sensitive" — and AppKit matches
/// `keyEquivalentModifierMask` against the full device-independent set, which
/// for an arrow key includes `.function` and `.numericPad` that the user never
/// pressed. So the decision lives here, in a local `NSEvent` monitor, which
/// runs before `NSApplication.sendEvent` offers the event to the main menu.
///
/// **Cmd+Shift+[ / ].** Previous / next session, wherever focus is — the
/// binding Warp, Terminal and Safari use. Option+Up/Down can't do this job
/// from a focused terminal, which is where the user almost always is: there it
/// belongs to the CLI. A menu key equivalent can't do it either: AppKit
/// matches against `charactersIgnoringModifiers`, which has Shift applied, so
/// the event says "{" and a "[" binding never fires, while binding "{" is dead
/// on layouts that need Option to type it. So it's matched here, by the key
/// that types `[` / `]` with ⌘ held (`CommandKeyLayer`). A layout with no such key
/// (Icelandic, German — Option is needed) falls back to the US key position,
/// whatever it prints there. Matching the US position on every layout would
/// take ⌘? and ⌘⇧= from Dvorak.
///
/// The decision itself is `action(keyCode:modifiers:…)` — pure, and
/// unit-tested without a GUI.
@MainActor
enum TerminalKeyInterceptor {
    private static var monitor: Any?
    /// Set at install time so the non-terminal branch can reach the services.
    private static var appDelegate: AppDelegate?
    /// macOS virtual keycode for the Return key (next to right-shift). The
    /// numeric keypad's Enter has its own keycode (76); both behave
    /// identically as far as users expect, but we only target the main
    /// Return key here to avoid accidentally rewriting numeric-keypad
    /// scenarios.
    private static let returnKeyCode: UInt16 = 36

    /// macOS virtual keycodes for the arrow keys we rewrite.
    private static let upKeyCode: UInt16 = 126
    private static let downKeyCode: UInt16 = 125
    /// `kVK_ANSI_LeftBracket` / `kVK_ANSI_RightBracket` — key positions, not
    /// characters. Only used for layouts with no bracket key.
    private static let leftBracketKeyCode: UInt16 = 33
    private static let rightBracketKeyCode: UInt16 = 30

    /// ESC + CR. Claude Code, codex and other CLIs read this as "insert a
    /// newline into the input" rather than "submit". Matches iTerm2.
    static let shiftReturnBytes: [UInt8] = [0x1B, 0x0D]
    /// `ESC [ 1 ; 3 A` / `ESC [ 1 ; 3 B` — xterm's encoding for Alt+Up/Down
    /// (modifier parameter 3 = alt).
    static let altUpBytes: [UInt8] = [0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x41]
    static let altDownBytes: [UInt8] = [0x1B, 0x5B, 0x31, 0x3B, 0x33, 0x42]

    static func install(appDelegate: AppDelegate? = nil) {
        guard monitor == nil else { return }
        Self.appDelegate = appDelegate
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    // swiftlint:disable function_parameter_count
    /// The whole decision, as a pure function. `modifiers` is passed raw —
    /// arrow events carry `.function` and `.numericPad` the user never pressed,
    /// so the relevant flags are masked out here rather than at the call site.
    /// `commandCharacter` is what the key types with ⌘ held on the active
    /// layout. Both layout arguments are lazy: only ⌘⇧ events read the layout.
    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        commandCharacter: @autoclosure () -> String?,
        layoutTypesBrackets: @autoclosure () -> Bool,
        isTerminalFocused: Bool,
        isMainWindow: Bool
    ) -> TerminalKeyAction {
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = modifiers.intersection(relevant)
        switch keyCode {
        case returnKeyCode where mods == .shift && isTerminalFocused:
            return .sendBytes(shiftReturnBytes)
        case upKeyCode where mods == .option:
            if isTerminalFocused { return .sendBytes(altUpBytes) }
            return isMainWindow ? .previousSession : .passThrough
        case downKeyCode where mods == .option:
            if isTerminalFocused { return .sendBytes(altDownBytes) }
            return isMainWindow ? .nextSession : .passThrough
        case _ where mods == [.command, .shift]:
            return bracketAction(
                keyCode: keyCode, commandCharacter: commandCharacter,
                layoutTypesBrackets: layoutTypesBrackets, isMainWindow: isMainWindow
            )
        default:
            return .passThrough
        }
    }

    // swiftlint:enable function_parameter_count

    /// Cmd+Shift+[ / ]: the layout's bracket keys, else the US positions.
    private static func bracketAction(
        keyCode: UInt16,
        commandCharacter: () -> String?,
        layoutTypesBrackets: () -> Bool,
        isMainWindow: Bool
    ) -> TerminalKeyAction {
        let step: TerminalKeyAction
        switch commandCharacter() {
        case "[": step = .previousSession
        case "]": step = .nextSession
        case _ where keyCode == leftBracketKeyCode && !layoutTypesBrackets():
            step = .previousSession
        case _ where keyCode == rightBracketKeyCode && !layoutTypesBrackets():
            step = .nextSession
        default:
            return .passThrough
        }
        return isMainWindow ? step : .passThrough
    }

    /// True when we consumed the event.
    private static func handle(_ event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder as? NSView
        let terminalView = Self.closestTerminalView(from: responder)
        lazy var layer = CommandKeyLayer.current()
        let decision = action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            commandCharacter: layer?.character(keyCode: event.keyCode),
            // Unreadable layout: don't take the US positions.
            layoutTypesBrackets: layer?.typesBrackets ?? true,
            isTerminalFocused: terminalView != nil,
            isMainWindow: WindowFrameAutosave.isMainWindow(
                autosaveName: event.window?.frameAutosaveName
            )
        )
        switch decision {
        case .passThrough:
            return false
        case let .sendBytes(bytes):
            guard let terminalView else { return false }
            terminalView.send(bytes)
            return true
        case .previousSession:
            return step(by: -1)
        case .nextSession:
            return step(by: 1)
        }
    }

    /// Move the sidebar selection. Returns false when the service graph isn't
    /// up yet, so the event falls through rather than vanishing.
    private static func step(by delta: Int) -> Bool {
        guard let services = appDelegate?.services else {
            YggdrasilLog.ui.error("Keyboard session step: AppServices unavailable")
            return false
        }
        SidebarActions.selectTab(by: delta, services: services)
        return true
    }

    /// Walk responder chain upward to the nearest `LocalProcessTerminalView`.
    static func closestTerminalView(from view: NSView?) -> LocalProcessTerminalView? {
        var current: NSView? = view
        while let candidate = current {
            if let term = candidate as? LocalProcessTerminalView { return term }
            current = candidate.superview
        }
        return nil
    }
}
