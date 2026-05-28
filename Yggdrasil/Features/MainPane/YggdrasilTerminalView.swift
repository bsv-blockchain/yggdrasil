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

/// `LocalProcessTerminalView` subclass that accepts file drops. When the user
/// drags one or more files from Finder (or any source that publishes file
/// URLs) onto the terminal pane, the paths are inserted at the prompt as a
/// space-separated, shell-quoted list. Matches iTerm2/Warp/Terminal.app.
///
/// Single drop = `'/path/to/file'`. Multiple drops are joined with spaces:
/// `'/path/a' '/path/b'`. The result is sent to the PTY via `send(txt:)` —
/// the running program (shell or agent CLI) sees it as if the user had
/// typed those characters.
@MainActor
final class DroppableTerminalView: LocalProcessTerminalView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil)
            ? .copy
            : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pasteboard = sender.draggingPasteboard
        guard let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        let payload = urls
            .map { DroppableTerminalView.shellQuote($0.path) }
            .joined(separator: " ")
        send(txt: payload)
        return true
    }

    /// Wraps a path in single quotes, escaping any embedded single quotes
    /// the POSIX way (`'\''`). Same algorithm `CodingAgentRunner.shellQuote`
    /// uses but inlined to avoid pulling the runner into the view layer.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Registry of every live `LocalProcessTerminalView` so the Option-drag
/// bypass can flip `allowMouseReporting` without relying on AppKit hit-
/// testing (which is fragile across the SwiftUI/NSHostingView boundary).
/// `AgentTerminalSurface.makeNSView` registers; `dismantleNSView` would
/// remove (but views typically live for the whole app session so we don't
/// require strict deregistration — the set is held weakly).
@MainActor
enum TerminalViewRegistry {
    private static let storage = NSHashTable<LocalProcessTerminalView>.weakObjects()

    static func register(_ view: LocalProcessTerminalView) {
        storage.add(view)
    }

    static func allViews() -> [LocalProcessTerminalView] {
        storage.allObjects
    }
}

/// Shift-drag selection bypass. tmux is configured with `mouse on` so the
/// scroll wheel can drive tmux's copy-mode (see `TerminalScrollInterceptor`).
/// The side-effect is that `LocalProcessTerminalView.allowMouseReporting`
/// forwards every left-mouse-down to the PTY as a mouse event, which means
/// the user can never just drag-select text — the drag becomes a tmux
/// mouse-drag.
///
/// To match iTerm2/Terminal.app/Warp, while Shift is held we suppress
/// mouse reporting on every live terminal view: SwiftTerm's native
/// selection takes over. When Shift is released, reporting is restored so
/// scroll wheels still drive tmux copy-mode.
///
/// We watch `.flagsChanged` (modifier key transitions) rather than
/// per-click events because: (a) it doesn't depend on AppKit hit-testing
/// finding the right view through SwiftUI's host layer; (b) it handles
/// the case where the user presses Shift BEFORE clicking; (c) it
/// correctly handles long drags that outlast a single mouse-down event.
@MainActor
enum TerminalMouseSelectionBypass {
    private static var flagsMonitor: Any?
    /// Views whose `allowMouseReporting` we forced false while Option was
    /// held, so we know which to restore when Option releases. Stored
    /// strongly here for the brief life of one Option-hold; cleared on
    /// release.
    private static var suppressedViews: [LocalProcessTerminalView] = []

    static func install() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handleFlagsChanged(event)
            return event
        }
    }

    private static func handleFlagsChanged(_ event: NSEvent) {
        let shiftDown = event.modifierFlags.contains(.shift)
        if shiftDown, suppressedViews.isEmpty {
            for view in TerminalViewRegistry.allViews() where view.allowMouseReporting {
                view.allowMouseReporting = false
                suppressedViews.append(view)
            }
        } else if !shiftDown, !suppressedViews.isEmpty {
            for view in suppressedViews {
                view.allowMouseReporting = true
            }
            suppressedViews.removeAll()
        }
    }
}
