import AppKit
import SwiftTerm

/// App-wide scroll-wheel interceptor. SwiftTerm's `LocalProcessTerminalView`
/// has a public-but-not-open `scrollWheel` that always scrolls SwiftTerm's
/// own buffer — useless inside tmux, which owns the screen and keeps its
/// own scrollback. We can't subclass-override, so we install a local
/// NSEvent monitor that fires BEFORE the view sees the event: when the
/// event lands on a `LocalProcessTerminalView` whose embedded terminal has
/// opted into mouse reporting (the case once tmux's `set-option mouse on`
/// has run), we encode the scroll as an SGR-1006 button-64/65 event and
/// send it to the PTY via `terminal.sendEvent(...)`. tmux interprets that
/// as wheel input, enters copy-mode, and scrolls its real history. Outside
/// tmux (no mouse-reporting), the monitor returns the event untouched and
/// SwiftTerm's native scrollback runs.
@MainActor
enum TerminalScrollInterceptor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            handleScroll(event) ? nil : event
        }
    }

    /// True when we consumed the event (don't propagate further).
    private static func handleScroll(_ event: NSEvent) -> Bool {
        guard let contentView = event.window?.contentView else { return false }
        // Find a LocalProcessTerminalView under the cursor. We use a regular
        // hit test instead of inspecting the responder chain because the
        // chain might point at one of SwiftTerm's internal subviews; the
        // hit test surfaces the same NSView the user is pointing at.
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(pointInContent),
              let terminalView = closestTerminalView(from: hit) else {
            return false
        }
        let term = terminalView.terminal!
        guard terminalView.allowMouseReporting, term.mouseMode != .off else {
            return false
        }
        let deltaY = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        guard deltaY != 0 else { return true }

        let local = terminalView.convert(event.locationInWindow, from: nil)
        let cell = cellAt(local, in: terminalView, term: term)
        // SGR-1006 button codes: 64 = wheel up, 65 = wheel down.
        let buttonFlag = deltaY > 0 ? 64 : 65
        // One event per cell of scroll distance, capped so a flick doesn't
        // dump dozens.
        let lines = max(1, min(Int(abs(deltaY)), 8))
        for _ in 0..<lines {
            term.sendEvent(buttonFlags: buttonFlag, x: cell.col, y: cell.row)
        }
        return true
    }

    static func closestTerminalView(from view: NSView?) -> LocalProcessTerminalView? {
        var current: NSView? = view
        while let candidate = current {
            if let term = candidate as? LocalProcessTerminalView { return term }
            current = candidate.superview
        }
        return nil
    }

    private static func cellAt(_ point: NSPoint, in view: NSView, term: Terminal) -> (col: Int, row: Int) {
        let cols = max(1, term.cols)
        let rows = max(1, term.rows)
        let cellWidth = view.bounds.width / CGFloat(cols)
        let cellHeight = view.bounds.height / CGFloat(rows)
        guard cellWidth > 0, cellHeight > 0 else { return (0, 0) }
        let col = max(0, min(cols - 1, Int(point.x / cellWidth)))
        // SwiftTerm's row origin is top-left; NSView origin is bottom-left.
        let invertedY = view.bounds.height - point.y
        let row = max(0, min(rows - 1, Int(invertedY / cellHeight)))
        return (col, row)
    }

}

/// Shift+Enter rewriter. SwiftTerm's default `keyDown` handler routes Return
/// (with or without Shift) through `interpretKeyEvents`, which on macOS maps
/// to `insertNewline:` and sends a plain CR (`\r`) to the PTY. Claude Code
/// (and most other agents) treat plain CR as "submit"; they look for
/// `ESC + CR` (`\e\r`) — the same encoding iTerm2 emits — to insert a
/// literal newline into the input buffer.
///
/// We install a global `NSEvent` local monitor for `.keyDown` events. When
/// the key event is Return with *only* the Shift modifier and lands on a
/// `LocalProcessTerminalView`, we send `\e\r` directly via
/// `view.send([UInt8])` and swallow the event so SwiftTerm doesn't also fire
/// the default CR.
@MainActor
enum TerminalKeyInterceptor {
    private static var monitor: Any?
    /// macOS virtual keycode for the Return key (next to right-shift). The
    /// numeric keypad's Enter has its own keycode (76); both behave
    /// identically as far as users expect, but we only target the main
    /// Return key here to avoid accidentally rewriting numeric-keypad
    /// scenarios.
    private static let returnKeyCode: UInt16 = 36

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event) ? nil : event
        }
    }

    /// True when we consumed the event.
    private static func handle(_ event: NSEvent) -> Bool {
        guard event.keyCode == returnKeyCode else { return false }
        let relevant: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
        let mods = event.modifierFlags.intersection(relevant)
        // Only the shift modifier — nothing else combined.
        guard mods == .shift else { return false }
        guard let responder = event.window?.firstResponder as? NSView,
              let terminalView = TerminalScrollInterceptor.closestTerminalView(from: responder)
        else {
            return false
        }
        // ESC (0x1b) + CR (0x0d). Claude Code, codex, and other CLIs read
        // this sequence as "insert newline into input" rather than
        // "submit". Matches iTerm2's default Shift+Enter behavior.
        terminalView.send([0x1b, 0x0d])
        return true
    }
}

/// Option-drag selection bypass. tmux is configured with `mouse on` so the
/// scroll wheel can drive tmux's copy-mode (see `TerminalScrollInterceptor`).
/// The side-effect is that `LocalProcessTerminalView.allowMouseReporting`
/// forwards every left-mouse-down to the PTY as a mouse event, which means
/// the user can never just drag-select text — the drag becomes a tmux
/// mouse-drag.
///
/// To match iTerm2/Terminal.app, holding Option while dragging temporarily
/// suppresses mouse reporting on the targeted terminal view: SwiftTerm's
/// native selection takes over for the duration of the drag, then mouse
/// reporting is restored on mouse-up so subsequent scroll-wheel events
/// still reach tmux.
@MainActor
enum TerminalMouseSelectionBypass {
    private static var downMonitor: Any?
    private static var upMonitor: Any?
    private static weak var suppressedView: LocalProcessTerminalView?

    static func install() {
        guard downMonitor == nil else { return }
        downMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handleDown(event)
            return event
        }
        upMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            handleUp()
            return event
        }
    }

    private static func handleDown(_ event: NSEvent) {
        guard event.modifierFlags.contains(.option) else { return }
        guard let contentView = event.window?.contentView else { return }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        guard let hit = contentView.hitTest(pointInContent),
              let terminalView = TerminalScrollInterceptor.closestTerminalView(from: hit)
        else { return }
        // Only flip when mouse reporting was actually on — otherwise we'd
        // re-enable it on mouse-up where it wasn't enabled before.
        guard terminalView.allowMouseReporting else { return }
        terminalView.allowMouseReporting = false
        suppressedView = terminalView
    }

    private static func handleUp() {
        guard let view = suppressedView else { return }
        view.allowMouseReporting = true
        suppressedView = nil
    }
}
