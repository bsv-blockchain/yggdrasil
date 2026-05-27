import AppKit
import Foundation

/// Right-click context-menu actions for sidebar rows. Pure side-effects — kept
/// outside the SwiftUI view so they're unit-testable in isolation if we want.
enum SidebarActions {

    /// Reveal the worktree directory in Finder. Falls back to "open the parent"
    /// if the path itself can't be reached (e.g. the worktree was deleted).
    static func openInFinder(path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
        YggdrasilLog.ui.info("Reveal in Finder: \(path, privacy: .public)")
    }

    /// Open Terminal.app at the worktree path.
    static func openInTerminal(path: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open(
            [url], withApplicationAt: terminalURL,
            configuration: config
        ) { _, error in
            if let error {
                YggdrasilLog.ui.error("Open Terminal.app failed: \(String(describing: error), privacy: .public)")
            } else {
                YggdrasilLog.ui.info("Opened Terminal.app at \(path, privacy: .public)")
            }
        }
    }

    /// Confirm-then-delete a tab. Also tears down any running session for that tab.
    static func removeTab(id: Int64, services: AppServices) {
        let alert = NSAlert()
        alert.messageText = "Remove this tab?"
        alert.informativeText = "The tab will be removed from the sidebar. The worktree on disk is left untouched."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        services.sessions.remove(id: id)
        do {
            try services.tabStore.delete(id: id)
        } catch {
            YggdrasilLog.ui.error("Failed to delete tab \(id, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        services.tabs.reload()
    }
}
