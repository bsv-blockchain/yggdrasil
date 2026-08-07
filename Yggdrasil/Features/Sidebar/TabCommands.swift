import AppKit
import SwiftUI

/// Window-wide keyboard shortcuts for sidebar navigation. Folded into the
/// system View menu (after "Show Sidebar") rather than a custom top-level
/// menu, since these all act on sidebar selection.
///
/// - ⌥↑ / ⌥↓ — previous / next session. Arrow keys rather than ⌘⇧[ / ⌘⇧]:
///   AppKit matches a key equivalent against the event's
///   `charactersIgnoringModifiers`, so a bracket binding has to be written as
///   the shifted glyph "{" / "}" — and on any layout where those need Option
///   (Icelandic, German, Nordic) no keystroke ever produces them with a bare
///   ⌘⇧ mask, leaving the menu advertising a shortcut that cannot fire.
/// - ⌘⇧W — close the selected tab (with confirm). Not ⌘W: `WindowGroup`
///   installs File ▸ Close on ⌘W, AppKit walks the main menu in order, and
///   File precedes View — so ⌘W closes the window and never reaches here.
///
/// `appDelegate` is injected rather than looked up via
/// `NSApplication.shared.delegate as? AppDelegate` — that cast yields nil here,
/// so every item in this group silently did nothing until this was fixed.
/// `CodingMenuController` takes the same delegate by injection for this reason.
struct TabCommands: Commands {
    /// Plain reference, not `@ObservedObject`: every action reads
    /// `appDelegate.services` at click time, so observing buys nothing and
    /// would only add a `@Published`-driven main-menu rebuild racing
    /// `CodingMenuController`'s AppKit insertion at launch.
    let appDelegate: AppDelegate

    /// Runs `body` with the live service graph, or logs why it couldn't. Menu
    /// actions that no-op invisibly are the exact failure this group shipped
    /// with — never fail silently here again.
    ///
    /// Scoped to the main sessions window: Preferences and the four picker
    /// scenes share the same service graph, so without this an ⌥↓ typed at a
    /// picker would reorder the background main window's selection and leave
    /// the user typing into a different agent's terminal on return.
    private func withServices(_ label: String, _ body: (AppServices) -> Void) {
        guard WindowFrameAutosave.isMainWindow(autosaveName: NSApp.keyWindow?.frameAutosaveName) else {
            YggdrasilLog.ui.notice(
                "\(label, privacy: .public): main window not frontmost; menu action dropped"
            )
            return
        }
        guard let services = appDelegate.services else {
            YggdrasilLog.ui.error("\(label, privacy: .public): AppServices unavailable; menu action dropped")
            return
        }
        body(services)
    }

    /// A menu item whose log label is its title, so the two cannot drift.
    private func item(_ title: String, _ action: @escaping (AppServices) -> Void) -> some View {
        Button(title) { withServices(title) { action($0) } }
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            item("Previous Session") { SidebarActions.selectTab(by: -1, services: $0) }
                .keyboardShortcut(.upArrow, modifiers: [.option])

            item("Next Session") { SidebarActions.selectTab(by: 1, services: $0) }
                .keyboardShortcut(.downArrow, modifiers: [.option])

            item("Close Tab…") { services in
                guard let id = services.tabs.selectedID else {
                    YggdrasilLog.ui.notice("Close Tab…: no tab selected; nothing to close")
                    return
                }
                SidebarActions.removeTab(id: id, services: services)
            }
            .keyboardShortcut("W", modifiers: [.command, .shift])
            // ⌘T is bound to the "+" button in the sidebar header (Phase 4 Task 3).
        }
    }
}
