import SwiftUI

/// Window-wide keyboard shortcuts for sidebar navigation. Installed under the
/// "LoomTab" menu so they show up in the menu bar and aren't tied to sidebar focus.
///
/// - ⌥↑ / ⌥↓ — move selection up/down
/// - ⌘W — close the selected tab (with confirm)
/// - ⌘T — new tab (mirrors the sidebar "+" button)
struct TabCommands: Commands {
    private var services: AppServices? {
        (NSApplication.shared.delegate as? AppDelegate)?.services
    }

    var body: some Commands {
        CommandMenu("LoomTab") {
            Button("Previous") {
                services?.tabs.moveSelection(by: -1)
                if let id = services?.tabs.selectedID {
                    services?.sessions.selectedID = id
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])

            Button("Next") {
                services?.tabs.moveSelection(by: 1)
                if let id = services?.tabs.selectedID {
                    services?.sessions.selectedID = id
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.option])

            Divider()

            Button("Close LoomTab…") {
                guard let services, let id = services.tabs.selectedID else { return }
                SidebarActions.removeTab(id: id, services: services)
            }
            .keyboardShortcut("w", modifiers: [.command])
            // ⌘T is bound to the "+" button in the sidebar header (Phase 4 Task 3).
        }
    }
}
