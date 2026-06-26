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

/// Bridges the mouse to the agent for things SwiftTerm doesn't do on its own,
/// via a global event monitor (SwiftTerm's `scrollWheel`/`mouseDown` are
/// `public`, not `open`, so they can't be overridden — same approach as
/// `TerminalKeyInterceptor`). Two jobs:
///
/// 1. **Wheel forwarding.** SwiftTerm's `scrollWheel` only ever moves its own
///    native scrollback and never forwards to the app. A full-screen TUI in the
///    alternate buffer (e.g. Claude Code's fullscreen renderer) has no native
///    scrollback, so the wheel did nothing. We translate the wheel into
///    mouse-wheel events when the app reads the mouse, or cursor up/down keys in
///    a non-mouse alt buffer (standard "alternate scroll", à la xterm/iTerm).
///
/// 2. **Keeping `allowMouseReporting` in sync with the live `mouseMode`.** When
///    the agent is reading the mouse we want clicks/drags forwarded (so
///    click-to-expand and the agent's own selection work); otherwise we want it
///    off so SwiftTerm preserves the native text selection across streaming
///    output (it clears the selection on each line feed while reporting is on).
///    `mouseModeChanged` isn't overridable either, so we re-sync the flag on
///    every mouse/scroll event — always correct by the time the view handles it.
@MainActor
enum TerminalMouseInterceptor {
    private static var monitor: Any?

    /// What to do with a wheel notch, given the focused terminal's state. Pure
    /// so the routing is unit-testable; the side-effecting send lives in `handle`.
    enum Action: Equatable {
        /// Let SwiftTerm scroll its native scrollback (normal buffer, no mouse).
        case native
        /// Forward as a mouse-wheel button (the app reads the mouse).
        case mouseWheel(upward: Bool)
        /// Alternate-scroll: cursor up/down keys (alt buffer, no mouse).
        case arrowKeys(upward: Bool, applicationCursor: Bool)
    }

    static func action(
        mouseTracking: Bool, alternateBuffer: Bool, upward: Bool, applicationCursor: Bool
    ) -> Action {
        if mouseTracking { return .mouseWheel(upward: upward) }
        if alternateBuffer { return .arrowKeys(upward: upward, applicationCursor: applicationCursor) }
        return .native
    }

    static func install() {
        guard monitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .rightMouseDown, .otherMouseDown
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { event in
            handle(event) ? nil : event
        }
    }

    /// True only when we forwarded a *scroll* to the agent (event should be
    /// swallowed). Mouse-button events are never swallowed — we only re-sync
    /// `allowMouseReporting` and let the view handle them.
    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window ?? NSApp.keyWindow,
              let hit = window.contentView?.hitTest(event.locationInWindow),
              let view = TerminalKeyInterceptor.closestTerminalView(from: hit)
        else { return false }

        let terminal = view.getTerminal()
        // Keep mouse forwarding aligned with whether the agent reads the mouse.
        view.allowMouseReporting = terminal.mouseMode != .off

        // Only scroll-wheel events are bridged/swallowed below; button events
        // were handled by the re-sync above and pass through to the view.
        guard event.type == .scrollWheel, event.deltaY != 0 else { return false }

        let upward = event.deltaY > 0
        let action = action(
            mouseTracking: terminal.mouseMode != .off,
            alternateBuffer: terminal.isCurrentBufferAlternate,
            upward: upward,
            applicationCursor: terminal.applicationCursor
        )
        // One notch per ~line of delta, capped so a hard flick doesn't fling.
        let notches = max(1, min(5, Int(abs(event.deltaY).rounded(.up))))

        switch action {
        case .native:
            return false
        case let .mouseWheel(upward):
            let point = view.convert(event.locationInWindow, from: nil)
            let (col, row) = cell(at: point, in: view, terminal: terminal)
            let flags = terminal.encodeButton(
                button: upward ? 4 : 5, release: false, shift: false, meta: false, control: false
            )
            for _ in 0 ..< notches {
                terminal.sendEvent(buttonFlags: flags, x: col, y: row)
            }
            return true
        case let .arrowKeys(upward, applicationCursor):
            let seq: [UInt8] = applicationCursor
                ? (upward ? [0x1B, 0x4F, 0x41] : [0x1B, 0x4F, 0x42]) // SS3 A / B
                : (upward ? [0x1B, 0x5B, 0x41] : [0x1B, 0x5B, 0x42]) // CSI A / B
            for _ in 0 ..< notches {
                view.send(seq)
            }
            return true
        }
    }

    /// Approximate terminal cell under `point` (view coords). SwiftTerm's exact
    /// hit-test is internal; cols/rows + bounds give a good-enough wheel
    /// position (apps scroll on the wheel button regardless of the exact cell).
    private static func cell(
        at point: CGPoint, in view: LocalProcessTerminalView, terminal: Terminal
    ) -> (col: Int, row: Int) {
        let cols = max(1, terminal.cols)
        let rows = max(1, terminal.rows)
        let width = view.bounds.width
        let height = view.bounds.height
        guard width > 0, height > 0 else { return (0, 0) }
        let col = min(max(0, Int(point.x / (width / CGFloat(cols)))), cols - 1)
        // AppKit's y is bottom-up; terminal row 0 is at the top.
        let row = min(max(0, Int((height - point.y) / (height / CGFloat(rows)))), rows - 1)
        return (col, row)
    }
}

/// `LocalProcessTerminalView` subclass with two enhancements:
///
/// 1. **File drag-and-drop** — paths from Finder are shell-quoted and sent
///    to the PTY at the prompt. Matches iTerm2/Warp/Terminal.app.
///
/// 2. **Don't snap to bottom on output while the user is reading history.**
///    SwiftTerm's `Terminal.scroll()` snaps the viewport to `yBase` on every
///    new line — its internal `userScrolling` gate is never set in 1.x and is
///    module-internal, so we can't suppress the snap. Instead we record where
///    the user parked the viewport and restore it after each output-driven
///    snap.
///
///    The two `scrolled` overrides split cleanly by call path, with no
///    timing/event-monitor guesswork:
///    - `scrolled(source:yDisp:)` (Terminal delegate) fires ONLY for output.
///      It restores the parked position after the snap.
///    - `scrolled(source:position:)` (view delegate) fires for every *user*
///      scroll (wheel/trackpad/slider/page) via `scrollTo`. Output also
///      reaches it (the yDisp override forwards through `super`), flagged by
///      `inOutputScroll`; only a direct user scroll updates the parked
///      position.
@MainActor
final class DroppableTerminalView: LocalProcessTerminalView {
    /// nil = follow tail; Double in [0, 1) = the position the user pinned
    /// the viewport at while reading history. Stored as a fractional
    /// position rather than a row index so it survives scrollback trim.
    private var userFrozenAtPosition: Double?
    /// Re-entrance guard: our own `scroll(toPosition:)` triggers `scrolled`
    /// again.
    private var inRestore = false
    /// True only while inside the output-driven `scrolled(source:yDisp:)`
    /// path, so the view-level `scrolled(source:position:)` it forwards into
    /// can tell an output snap from a genuine user scroll — deterministically,
    /// by call path, rather than via an NSEvent-timing flag.
    private var inOutputScroll = false

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
        inOutputScroll = true
        super.scrolled(source: terminal, yDisp: yDisp)
        inOutputScroll = false
        guard !inRestore, let frozen = userFrozenAtPosition, scrollPosition >= 1.0 else { return }
        inRestore = true
        scroll(toPosition: frozen)
        inRestore = false
    }

    /// View-level callback — fires for every *user* scroll (wheel, trackpad,
    /// slider, page up/down), all of which route through `scrollTo`. Output
    /// also reaches here, but only via `scrolled(source:yDisp:)` → `super`,
    /// flagged by `inOutputScroll`. A direct call (not in output, not our own
    /// restore) is therefore a genuine user scroll → record where they parked.
    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        guard !inRestore, !inOutputScroll else { return }
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
