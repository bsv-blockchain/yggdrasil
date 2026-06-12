import SwiftUI

/// Adds "Check for Updates…" to the application menu (right after the About
/// item, the macOS-standard location). The button lives in a small `View` so
/// it can observe `UpdaterController.canCheckForUpdates` and disable itself
/// while a check is running — observation has to happen in a `View`, not in the
/// `Commands` struct itself.
struct UpdaterCommands: Commands {
    let updater: UpdaterController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesView(updater: updater)
        }
    }
}

private struct CheckForUpdatesView: View {
    @ObservedObject var updater: UpdaterController

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
