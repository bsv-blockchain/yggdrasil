import AppKit

/// Stamps the focused terminal whenever the user presses a key or uses the
/// mouse in it, so `ClipboardGuardDelegate` can tell a copy the user asked
/// for from bytes an agent printed on its own.
///
/// A local event monitor because SwiftTerm's `keyDown`/`mouseDown`/`mouseUp`
/// are `public`, not `open`. The guard's own `send` sees every key too, but
/// also the emulator's automatic replies to queries, which printed bytes can
/// trigger, so it can't tell the user apart from the output.
@MainActor
enum TerminalInputClock {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .leftMouseUp, .leftMouseDragged, .rightMouseDown, .otherMouseDown]
        ) { event in
            let responder = event.window?.firstResponder
            var isInsideView = true
            if let view = responder as? NSView, event.type != .keyDown {
                isInsideView = view.bounds.contains(view.convert(event.locationInWindow, from: nil))
            }
            if shouldStamp(eventType: event.type, modifiers: event.modifierFlags, isInsideView: isInsideView) {
                stamp(firstResponder: responder)
            }
            return event
        }
    }

    /// A key typed into the terminal, or a click or drag within its frame. ⌘
    /// shortcuts aren't input to the agent: counting them would let an OSC 52
    /// write overwrite what the user's own ⌘C just copied. A click elsewhere
    /// in the window (the sidebar, say) isn't either; one on an overlay drawn
    /// over the terminal, like the find bar, does count.
    static func shouldStamp(eventType: NSEvent.EventType, modifiers: NSEvent.ModifierFlags,
                            isInsideView: Bool) -> Bool {
        if eventType == .keyDown { return !modifiers.contains(.command) }
        return isInsideView
    }

    /// Only a terminal on the selected tab: a deselected one can keep focus
    /// while hidden when the newly selected tab has no terminal to take it.
    static func stamp(firstResponder: NSResponder?, at now: ContinuousClock.Instant = .now) {
        guard let view = firstResponder as? DroppableTerminalView, view.isSelectedTab else { return }
        view.lastUserInputAt = now
    }
}
