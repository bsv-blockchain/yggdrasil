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
///
/// `appDelegate` is injected rather than looked up via
/// `NSApplication.shared.delegate as? AppDelegate` — that cast yields nil here,
/// so every item in this group silently did nothing (⌘W included) until 0.5.15.
/// `CodingMenuController` takes the same delegate by injection for this reason.
struct TabCommands: Commands {
    @ObservedObject var appDelegate: AppDelegate

    private var services: AppServices? {
        appDelegate.services
    }

    /// Runs `body` with the live service graph, or logs why it couldn't. Menu
    /// actions that no-op invisibly are the exact failure this group shipped
    /// with for eleven releases — never fail silently here again.
    private func withServices(_ label: String, _ body: (AppServices) -> Void) {
        guard let services else {
            YggdrasilLog.ui.error("\(label, privacy: .public): AppServices unavailable; menu action dropped")
            return
        }
        body(services)
    }

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Previous Session") {
                withServices("Previous Session") { SidebarActions.selectTab(by: -1, services: $0) }
            }
            .keyboardShortcut("{", modifiers: [.command, .shift])

            Button("Next Session") {
                withServices("Next Session") { SidebarActions.selectTab(by: 1, services: $0) }
            }
            .keyboardShortcut("}", modifiers: [.command, .shift])

            Button("Close Tab…") {
                withServices("Close Tab") { services in
                    guard let id = services.tabs.selectedID else { return }
                    SidebarActions.removeTab(id: id, services: services)
                }
            }
            .keyboardShortcut("w", modifiers: [.command])
            // ⌘T is bound to the "+" button in the sidebar header (Phase 4 Task 3).
        }
    }
}
