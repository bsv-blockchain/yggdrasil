import Combine
import Sparkle
import SwiftUI

/// Owns the Sparkle updater for the app.
///
/// Feed URL + EdDSA public key are read from the bundle's Info.plist
/// (`SUFeedURL` / `SUPublicEDKey`, set in `project.yml`). The controller is
/// created with `startingUpdater: false` so merely constructing it — which also
/// happens under XCTest, since the test bundle is hosted in the real app — has
/// no side effects (no scheduled network check, no first-run permission
/// prompt). Production calls `start()` exactly once from `RootView`.
@MainActor
final class UpdaterController: ObservableObject {
    let controller: SPUStandardUpdaterController

    /// Mirrors `SPUUpdater.canCheckForUpdates` so the menu item disables itself
    /// while a check is already in flight.
    @Published private(set) var canCheckForUpdates = false

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        controller.updater
            .publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }

    /// Begin scheduled background checks (honouring `SUScheduledCheckInterval`).
    /// Idempotent in practice — only ever called once, guarded against the test
    /// host.
    func start() {
        controller.startUpdater()
    }

    /// User-initiated check (Check for Updates… menu item). Sparkle presents
    /// its own progress/“up to date”/“update available” UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
