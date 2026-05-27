import SwiftUI

/// Window-wide keyboard shortcuts for sidebar navigation. Folded into the
/// system View menu (after "Show Sidebar") rather than a custom top-level
/// menu, since these all act on sidebar selection.
///
/// - ⌥↑ / ⌥↓ — move selection up/down
/// - ⌘W — close the selected tab (with confirm)
/// - ⌘T — new tab (mirrors the sidebar "+" button)
struct TabCommands: Commands {
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Previous Tab") {
                services?.tabs.moveSelection(by: -1)
                if let id = services?.tabs.selectedID {
                    services?.sessions.selectedID = id
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])

            Button("Next Tab") {
                services?.tabs.moveSelection(by: 1)
                if let id = services?.tabs.selectedID {
                    services?.sessions.selectedID = id
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.option])

            Button("Close Tab…") {
                guard let services, let id = services.tabs.selectedID else { return }
                SidebarActions.removeTab(id: id, services: services)
            }
            .keyboardShortcut("w", modifiers: [.command])
            // ⌘T is bound to the "+" button in the sidebar header (Phase 4 Task 3).
        }
    }
}
