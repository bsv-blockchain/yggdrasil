import Foundation
import SwiftTerm

/// Typing into a tab's agent and reading its screen, for the control API.
/// The bytes go the same way a keystroke does; they don't count as the
/// user's input, so they don't open the clipboard-write window either.
@MainActor
enum TerminalControl {
    struct Screen: Equatable {
        /// The visible rows, top to bottom, trailing blanks trimmed.
        let lines: [String]
        /// Up to the requested number of lines from just above the screen.
        let scrollback: [String]
        /// 0-based, within `lines`.
        let cursorRow: Int
        let cursorColumn: Int
        /// True while a full-screen program (like Claude's TUI) is drawing.
        let alternateScreen: Bool
    }

    /// Enter: what submits in Claude's prompt (Shift+Return, ESC CR, is a newline).
    static let submitKey: [UInt8] = [0x0D]

    /// `text` as typed. While the program has asked for bracketed paste it's
    /// sent as a paste, so a newline in it stays text instead of submitting.
    static func input(_ text: String, bracketedPaste: Bool) -> [UInt8] {
        var bytes = Array(text.utf8)
        guard bracketedPaste else { return bytes }
        // No ESC inside a paste: an end marker in the text, however it's
        // put together, would turn the rest of it into live keystrokes.
        bytes.removeAll { $0 == 0x1B }
        guard !bytes.isEmpty else { return [] }
        return EscapeSequences.bracketedPasteStart + bytes + EscapeSequences.bracketedPasteEnd
    }

    /// Types `text`, then with `submit` presses Enter in a separate write: a
    /// TUI reading a paste can take a CR in the same read as part of it.
    /// `paste` false sends plain keystrokes, escape sequences included.
    static func send(_ text: String, submit: Bool, paste: Bool = true, to view: TerminalView) async {
        let bytes = input(text, bracketedPaste: paste && view.getTerminal().bracketedPasteMode)
        if !bytes.isEmpty { view.send(bytes) }
        guard submit else { return }
        if !bytes.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        view.send(submitKey)
    }

    static func screen(of view: TerminalView, scrollback: Int) -> Screen {
        let terminal = view.getTerminal()
        // Cells nothing wrote to come back as NUL.
        let text = (String(bytes: terminal.getBufferAsData(kind: .active), encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\u{0}", with: " ")
        var all = text.components(separatedBy: "\n")
        if all.last?.isEmpty == true { all.removeLast() }
        let rows = terminal.rows
        let screenStart = max(all.count - rows, 0)
        let cursor = terminal.getCursorLocation()
        return Screen(
            lines: Array(all[screenStart...]),
            scrollback: Array(all[max(screenStart - max(scrollback, 0), 0) ..< screenStart]),
            cursorRow: cursor.y,
            cursorColumn: cursor.x,
            alternateScreen: terminal.isCurrentBufferAlternate
        )
    }
}
