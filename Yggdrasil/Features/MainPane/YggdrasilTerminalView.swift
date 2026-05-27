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

    private static func closestTerminalView(from view: NSView) -> LocalProcessTerminalView? {
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
