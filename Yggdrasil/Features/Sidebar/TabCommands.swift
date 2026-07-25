import SwiftUI

/// Window-wide keyboard shortcuts for sidebar navigation. Folded into the
/// system View menu (after "Show Sidebar") rather than a custom top-level
/// menu, since these all act on sidebar selection.
///
/// - ⌘⇧[ / ⌘⇧] — previous / next session (⌥↑ / ⌥↓ also work, see YggdrasilApp).
///   Bound as the *shifted* glyphs "{" / "}": AppKit matches a key equivalent
///   against the event's `charactersIgnoringModifiers`, which has Shift already
///   applied — "[" with `.shift` never matches and silently does nothing.
///   Same convention as ⌘⇧I in SidebarView and ⌘⇧R/S/N in CodingMenuController.
/// - ⌘W — close the selected tab (with confirm)
/// - ⌘T — new tab (mirrors the sidebar "+" button)
struct TabCommands: Commands {
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Previous Session") {
                if let services { SidebarActions.selectTab(by: -1, services: services) }
            }
            .keyboardShortcut("{", modifiers: [.command, .shift])

            Button("Next Session") {
                if let services { SidebarActions.selectTab(by: 1, services: services) }
            }
            .keyboardShortcut("}", modifiers: [.command, .shift])

            Button("Close Tab…") {
                guard let services, let id = services.tabs.selectedID else { return }
                SidebarActions.removeTab(id: id, services: services)
            }
            .keyboardShortcut("w", modifiers: [.command])
            // ⌘T is bound to the "+" button in the sidebar header (Phase 4 Task 3).
        }
    }
}
