import AppKit
import SwiftTerm
import UniformTypeIdentifiers

/// What the interceptor decided to do with a key event.
enum TerminalKeyAction: Equatable {
    /// Not ours — let AppKit and SwiftTerm have it.
    case passThrough
    /// Write these bytes to the focused terminal and swallow the event.
    case sendBytes([UInt8])
    case previousSession
    case nextSession
}

/// Key rewriter for the two keystrokes neither AppKit nor SwiftTerm gets right.
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
/// The decision itself is `action(keyCode:modifiers:isTerminalFocused:isMainWindow:)`
/// — pure, and unit-tested without a GUI.
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

    /// The whole decision, as a pure function. `modifiers` is passed raw —
    /// arrow events carry `.function` and `.numericPad` the user never pressed,
    /// so the relevant flags are masked out here rather than at the call site.
    static func action(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
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
        default:
            return .passThrough
        }
    }

    /// True when we consumed the event.
    private static func handle(_ event: NSEvent) -> Bool {
        let responder = event.window?.firstResponder as? NSView
        let terminalView = Self.closestTerminalView(from: responder)
        let decision = action(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
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
            YggdrasilLog.ui.error("Option+arrow session step: AppServices unavailable")
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

/// Cuts OSC 52 off from the pasteboard in both directions, while forwarding
/// every other `TerminalViewDelegate` callback to the terminal view itself.
///
/// **Reads.** SwiftTerm 1.15.0 answers `ESC ] 52 ; c ; ? BEL` by asking its
/// delegate for the clipboard and writing the base64 of whatever comes back
/// into the PTY (`Terminal.oscClipboard`). `TerminalViewDelegate`'s own default
/// denies that, but `LocalProcessTerminalView.clipboardRead` overrides it with
/// an unconditional `NSPasteboard.general` read — and the view is its own
/// `terminalDelegate`, so a plain subclass would inherit an always-allow
/// policy. Any bytes an agent prints (fetched web content, a build log, a file
/// it was asked to `cat`) could then echo the user's clipboard straight back
/// into the agent's stdin, and from there into model context. Clipboards hold
/// passwords and tokens.
///
/// **Writes.** The mirror image, and the same threat model: printed bytes can
/// silently replace whatever the user had copied. 1.15.0 widened the reach —
/// 1.13's `oscClipboard` required a literal `c;` prefix, 1.15's takes any
/// selection characters before the first `;` and treats an empty one as `c`.
/// Nothing in Yggdrasil needs an agent to drive the pasteboard, so it's denied
/// too; ⌘C and the context menu are unaffected, they don't route through here.
///
/// Neither `clipboardRead` nor `clipboardCopy` is `open`, so neither can be
/// overridden from a subclass — interposing on `terminalDelegate` is what's
/// left. Both callbacks route through it (`MacTerminalView.swift:3004-3010`).
/// Returning nil for the read is the documented deny: `Terminal.oscClipboard`
/// then sends no response at all.
final class ClipboardGuardDelegate: TerminalViewDelegate {
    /// Weak both ways round: the view retains this proxy, and SwiftTerm's own
    /// `terminalDelegate` reference is weak.
    private weak var target: LocalProcessTerminalView?

    init(target: LocalProcessTerminalView) {
        self.target = target
    }

    /// The process never gets the clipboard.
    func clipboardRead(source _: TerminalView) -> Data? {
        nil
    }

    /// …and never sets it either. Deliberately not forwarded to `target`,
    /// whose implementation writes straight to `NSPasteboard.general`.
    ///
    /// Logged because the denial is silent from the user's side and catches the
    /// benign case too: `nvim`/`tmux`/`ssh` yanking to the system clipboard over
    /// OSC 52 just does nothing. When someone reports that, this line is what
    /// distinguishes "we refused it" from "the sequence never arrived". The
    /// payload is deliberately not logged — only its size.
    func clipboardCopy(source _: TerminalView, content: Data) {
        YggdrasilLog.pty.debug("OSC 52 clipboard write refused (\(content.count, privacy: .public) bytes)")
    }

    // MARK: - Everything else forwards unchanged

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        target?.sizeChanged(source: source, newCols: newCols, newRows: newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        target?.setTerminalTitle(source: source, title: title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        target?.hostCurrentDirectoryUpdate(source: source, directory: directory)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        target?.send(source: source, data: data)
    }

    func scrolled(source: TerminalView, position: Double) {
        target?.scrolled(source: source, position: position)
    }

    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        target?.requestOpenLink(source: source, link: link, params: params)
    }

    func bell(source: TerminalView) {
        target?.bell(source: source)
    }

    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        target?.iTermContent(source: source, content: content)
    }

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        target?.rangeChanged(source: source, startY: startY, endY: endY)
    }
}

/// `LocalProcessTerminalView` subclass with these enhancements:
///
/// 1. **File drag-and-drop** — paths from Finder are shell-quoted and sent
///    to the PTY at the prompt. Matches iTerm2/Warp/Terminal.app.
///
/// 2. **OSC 52 clipboard reads and writes refused** — see `ClipboardGuardDelegate`.
///
/// 3. **Don't snap to bottom on output while the user is reading history.**
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
class DroppableTerminalView: LocalProcessTerminalView {
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
    /// Retains the delegate proxy that refuses clipboard reads — SwiftTerm's
    /// `terminalDelegate` reference is weak, so nothing else would.
    private var clipboardGuard: ClipboardGuardDelegate?

    override init(frame: CGRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        finishInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
        finishInit()
    }

    /// Wiring shared by both initialisers, applied after `super.init` has had
    /// its say (`LocalProcessTerminalView.init` points `terminalDelegate` at
    /// itself, which the clipboard guard has to take over).
    private func finishInit() {
        // SwiftTerm 1.15.0 changed the default from `.legacy` to `.overlay`,
        // which restyles the scrollbar and — because `reservedScrollerWidth`
        // drops to 0 when the scroller is hidden — shifts the width the cell
        // grid is computed from. Pin the pre-1.15 look so a mouse-reporting fix
        // doesn't drag an appearance change along; adopting `.overlay` is a
        // deliberate decision for its own change.
        scrollerStyle = .legacy
        let guardDelegate = ClipboardGuardDelegate(target: self)
        clipboardGuard = guardDelegate
        terminalDelegate = guardDelegate
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

    // MARK: - Mouse reporting sync

    /// Output arrives here before anything is parsed. Syncing on the way *out*
    /// is what keeps the flag honest across chunk boundaries: SwiftTerm reads
    /// `allowMouseReporting` in two places, and one of them —
    /// `AppleTerminalView.feedPrepare()` — runs at the top of every `feed`,
    /// before a single byte of that chunk has been looked at. A mode change in a
    /// chunk that carries no line feed would otherwise leave the flag stale
    /// until the next line feed or mouse event, and the following chunk's
    /// `feedPrepare` would clear a selection it should have left alone.
    ///
    /// `LocalProcess` posts this on `DispatchQueue.main` — it's constructed
    /// without a custom queue (`MacLocalTerminalView.swift:86`) — so this stays
    /// on the main actor like every other override here.
    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        allowMouseReporting = getTerminal().mouseMode != .off
    }

    /// The other reader: `linefeed` decides per line whether streaming output
    /// clears the native selection. Syncing here covers a mode change *within* a
    /// chunk, which `dataReceived` is too late for. `mouseModeChanged` is
    /// `public`, not `open`, so it can't be hooked directly — but these two
    /// cover every path there is: `mouseMode` only moves when the emulator
    /// parses a mode sequence, nothing here calls `feed` directly, and
    /// `softReset` leaves `mouseMode` alone.
    ///
    /// A global mouse-event monitor used to re-sync the flag as well. It was
    /// redundant once `dataReceived` carried the invariant, and its hit test
    /// picked the wrong view anyway: every tab is mounted in the window's
    /// `ZStack`, and `NSView.hitTest` ignores both `alphaValue` and SwiftUI's
    /// `allowsHitTesting`, so it resolved to the frontmost tab rather than the
    /// selected one. Wheel handling had already moved to upstream's
    /// `scrollWheel` in 1.15.0; there is nothing left for a monitor to do.
    override func linefeed(source: Terminal) {
        allowMouseReporting = source.mouseMode != .off
        super.linefeed(source: source)
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
