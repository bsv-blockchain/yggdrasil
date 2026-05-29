import AppKit
import SwiftTerm

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
              let terminalView = Self.closestTerminalView(from: responder)
        else {
            return false
        }
        // ESC (0x1b) + CR (0x0d). Claude Code, codex, and other CLIs read
        // this sequence as "insert newline into input" rather than
        // "submit". Matches iTerm2's default Shift+Enter behavior.
        terminalView.send([0x1b, 0x0d])
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

/// `LocalProcessTerminalView` subclass that accepts file drops. When the
/// user drags one or more files from Finder (or any source that publishes
/// file URLs) onto the terminal pane, the paths are inserted at the prompt
/// as a space-separated, shell-quoted list. Matches iTerm2/Warp/Terminal.app.
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
