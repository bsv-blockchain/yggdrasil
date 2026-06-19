import AppKit
import SwiftTerm
import UniformTypeIdentifiers

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
        terminalView.send([0x1B, 0x0D])
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

/// Tracks whether a user-input event is currently being dispatched.
/// Used by `DroppableTerminalView` to distinguish a `scrollTo` triggered
/// by the user (wheel scroll, keypress → ensureCaretIsVisible) from an
/// auto-snap-to-bottom triggered by the terminal's `scroll()` on output.
@MainActor
enum TerminalUserInputTracker {
    private static var monitor: Any?
    /// True during the dispatch of one user input event (set inside the
    /// `addLocalMonitorForEvents` block, cleared on the next runloop tick
    /// via `DispatchQueue.main.async`). NSEvent monitors fire before the
    /// responder chain receives the event, so the flag is set BEFORE
    /// SwiftTerm's view handler runs and stays set throughout — any
    /// `scrolled` callback during that dispatch sees `true`.
    private(set) static var dispatching = false

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.scrollWheel, .keyDown]
        ) { event in
            dispatching = true
            DispatchQueue.main.async { dispatching = false }
            return event
        }
    }
}

/// `LocalProcessTerminalView` subclass with two enhancements:
///
/// 1. **File drag-and-drop** — paths from Finder are shell-quoted and sent
///    to the PTY at the prompt. Matches iTerm2/Warp/Terminal.app.
///
/// 2. **Don't snap to bottom on output while the user is reading
///    history.** SwiftTerm's `Terminal.scroll()` snaps the viewport to
///    `yBase` whenever new output arrives unless its internal
///    `userScrolling` flag is set — but that flag is only wired for
///    slider-drag input, not for wheel scrolling. Without a fix,
///    reading scrollback while Claude writes means the view jumps to
///    the bottom on every new line.
///
///    The override watches the `scrolled` delegate callback. When the
///    callback fires AND we're scrolled up AND no user input event is
///    currently being dispatched, the viewport just got auto-snapped by
///    output — we restore it. User-driven scrolls (wheel, drag, or the
///    "ensureCaretIsVisible" path that runs on keypress) update the
///    freeze state directly without ever triggering an undo.
@MainActor
final class DroppableTerminalView: LocalProcessTerminalView {
    /// nil = follow tail; Double in [0, 1) = the position the user pinned
    /// the viewport at while reading history. Stored as a fractional
    /// position rather than a row index so it survives scrollback trim.
    private var userFrozenAtPosition: Double?
    /// Re-entrance guard: our own `scroll(toPosition:)` triggers `scrolled`
    /// again.
    private var inRestore = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    // MARK: - Scroll follow

    /// Terminal-level callback — fires when *output* advances the buffer
    /// (line feed → `Terminal.scroll`), which always snaps `yDisp` to the
    /// bottom (SwiftTerm's `userScrolling` gate is never set in 1.x, so it
    /// snaps unconditionally). If the user had parked the viewport up in
    /// history, put it back.
    override func scrolled(source terminal: Terminal, yDisp: Int) {
        super.scrolled(source: terminal, yDisp: yDisp)
        guard !inRestore, let frozen = userFrozenAtPosition, scrollPosition >= 1.0 else { return }
        inRestore = true
        scroll(toPosition: frozen)
        inRestore = false
    }

    /// View-level callback — fires for every *user* scroll (wheel, trackpad,
    /// slider, page up/down), all of which route through `scrollTo`. The
    /// Terminal-level `scrolled(source:yDisp:)` above does NOT fire for these,
    /// which is the bug: a wheel scroll-up never registered, `userFrozenAtPosition`
    /// stayed nil, and the next line of output snapped the viewport to the
    /// bottom. Capture the parked position here. The `dispatching` gate tells a
    /// genuine user scroll apart from the output-driven snap (which also lands
    /// here via the yDisp→position forward) and from our own restore.
    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        guard !inRestore, TerminalUserInputTracker.dispatching else { return }
        userFrozenAtPosition = Self.frozenTarget(forScrollPosition: position)
    }

    /// Maps a viewport scroll position to the freeze target: `nil` (follow the
    /// tail) when at/after the bottom, otherwise the fractional position to pin.
    static func frozenTarget(forScrollPosition pos: Double) -> Double? {
        pos >= 1.0 ? nil : pos
    }

    // MARK: - Image-aware paste

    /// Cmd-V. SwiftTerm's `paste` only knows about text, so an image on the
    /// clipboard is silently dropped. Claude Code (and other agents) accept an
    /// image by file path, so: if the clipboard holds an image, send a path to
    /// it — the existing file when the clipboard references one, otherwise a
    /// temp PNG written from the raw image bytes. Everything else falls through
    /// to SwiftTerm's normal text paste.
    override func paste(_ sender: Any) {
        if let payload = DroppableTerminalView.imagePastePayload(from: .general) {
            send(txt: payload)
            return
        }
        super.paste(sender)
    }

    /// Shell-quoted path(s) to send for an image on `pasteboard`, or nil when
    /// there's no image (caller should fall back to text paste). Prefers an
    /// existing on-disk image file; only writes a temp PNG for raw image data.
    static func imagePastePayload(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty, urls.allSatisfy(isImageFile) {
            return urls.map { shellQuote($0.path) }.joined(separator: " ")
        }
        if let data = pngData(from: pasteboard), let path = writeTempImage(data) {
            return shellQuote(path)
        }
        return nil
    }

    /// True for a file URL whose type conforms to `public.image`.
    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL,
              let type = UTType(filenameExtension: url.pathExtension)
        else { return false }
        return type.conforms(to: .image)
    }

    /// PNG bytes for any raw image on the pasteboard (PNG as-is, else TIFF /
    /// NSImage transcoded to PNG), or nil when there's no raw image data.
    static func pngData(from pasteboard: NSPasteboard) -> Data? {
        if let png = pasteboard.data(forType: .png) {
            return png
        }
        if let tiff = pasteboard.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        if let image = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)?.first as? NSImage,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            return rep.representation(using: .png, properties: [:])
        }
        return nil
    }

    /// Write `pngData` to a temp file and return its path, or nil on failure.
    static func writeTempImage(_ pngData: Data) -> String? {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Yggdrasil-pasted", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = dir.appendingPathComponent("pasted-\(UUID().uuidString).png")
            try pngData.write(to: url)
            return url.path
        } catch {
            YggdrasilLog.pty.error(
                "Failed to write pasted image: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    // MARK: - File drag-and-drop

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

// MARK: - Find

extension DroppableTerminalView: PaneFinder {
    func paneFind(_ query: String, forward: Bool) {
        guard !query.isEmpty else { return }
        if forward {
            findNext(query)
        } else {
            findPrevious(query)
        }
    }

    func paneClearFind() {
        clearSearch()
    }
}
